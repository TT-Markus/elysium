%%%------------------------------------------------------------------------------
%%% @copyright (c) 2014, DuoMark International, Inc.
%%% @author Jay Nelson <jay@duomark.com> [http://duomark.com/]
%%% @reference 2014 Development sponsored by TigerText, Inc. [http://tigertext.com/]
%%% @reference The license is based on the template for Modified BSD from
%%%   <a href="http://opensource.org/licenses/BSD-3-Clause">OSI</a>
%%% @doc
%%%   Elysium_bs_serial uses elysium_serial_queue for each of the session
%%%   and pending request queues. It doesn't allow any concurrency other
%%%   than these two gen_servers which internally maintain an erlang queue
%%%   of connections in the case of the session queue, and pid + reply_ref
%%%   in the case of pending CQL requests.
%%%
%%% @since 0.1.6i
%%% @end
%%%------------------------------------------------------------------------------
-module(elysium_bs_serial).
-author('jay@duomark.com').

-behaviour(elysium_buffering_strategy).
-behaviour(elysium_buffering_audit).

%% External API
-export([
         checkin_connection/4,
         checkout_connection/1,
         pend_request/2,
         handle_pending_request/6,
         insert_audit_counts/1,
         status/1
        ]).

%% Buffering audit API
-export([audit_count/2]).

-include("elysium_types.hrl").
-include("elysium_audit_types.hrl").

-record(audit_serial_counts, {
          count_type_key            :: {buffering_strategy_module(), counts},
          pending_dead          = 0 :: audit_count(),
          pending_timeouts      = 0 :: audit_count(),
          session_dead          = 0 :: audit_count(),
          session_decay         = 0 :: audit_count(),
          session_timeouts      = 0 :: audit_count(),
          session_wrong         = 0 :: audit_count(),
          worker_errors         = 0 :: audit_count(),
          worker_timeouts       = 0 :: audit_count()
         }).

-type audit_serial_counts() :: #audit_serial_counts{}.
-export_type([audit_serial_counts/0]).

-define(SERVER,     ?MODULE).
-define(COUNTS_KEY, {?MODULE, counts}).


%%%-----------------------------------------------------------------------
%%% External API
%%%-----------------------------------------------------------------------

-spec checkin_connection(config_type(), cassandra_node(), connection_id(), Is_New_Connection::boolean())
                        -> {boolean() | pending, {connection_queue_name(), Idle_Count, Max_Count}}
                               when Idle_Count :: max_connections(),
                                    Max_Count  :: max_connections().
%% @doc
%%   Checkin a seestar_session, IF there are no pending requests.
%%   A checkin will continue looping on the pending queue with
%%   the chance for decay on each attempt. If it decays, any
%%   newly spawned replacement is expected to check the pending
%%   queue for outstanding requests. Brand new connections are
%%   not checked for decay before first use.
%%
%%   This function can loop forever if there are pending requests,
%%   so it performs an asynchronous send_event.
%% @end
checkin_connection(Config, {_Ip, _Port} = Node, Connection_Id, Is_New_Connection)
  when is_pid(Connection_Id) ->
    Pending_Queue = elysium_config:requests_queue_name(Config),
    case is_process_alive(Connection_Id) andalso elysium_serial_queue:is_empty(Pending_Queue) of
        true  -> checkin_immediate (Config, Node, Connection_Id, Pending_Queue, Is_New_Connection);
        false -> checkin_pending   (Config, Node, Connection_Id, Pending_Queue, Is_New_Connection)
    end.

-spec checkout_connection(config_type()) -> {cassandra_node(), connection_id()} | none_available.
%% @doc
%%   Allocate a seestar_session to the caller by popping an entry
%%   from the front of the connection queue. This function either
%%   returns a live pid(), or none_available to indicate that all
%%   connections to Cassandra are currently checked out.
%%
%%   The configuration parameter is not validated because this
%%   function should be a hotspot and we don't want it to slow
%%   down or become a concurrency bottleneck.
%% @end
checkout_connection(Config) ->
    Session_Queue = elysium_config:session_queue_name (Config),
    Max_Retries   = elysium_config:checkout_max_retry (Config),
    fetch_pid_from_queue(Config, Session_Queue, Max_Retries, -1).

-spec pend_request(config_type(), query_request()) -> any() | pend_request_error().
%%   Block the caller while the request is serially queued. When
%%   a session is avialable to run this pending request, the
%%   blocking recieve loop will unblock and a spawned process
%%   will execute the request, so that the caller can still
%%   timeout if the request takes too long.
%% @end
pend_request(Config, Query_Request) ->
    Sid_Reply_Ref = make_ref(),
    Start_Time    = os:timestamp(),
    Pending_Queue = elysium_config:requests_queue_name   (Config),
    Reply_Timeout = elysium_config:request_reply_timeout (Config),
    wait_for_session(Config, Pending_Queue, Sid_Reply_Ref, Start_Time, Query_Request, Reply_Timeout).

%% Use the Connection_Id to run the query if we aren't out of time
handle_pending_request(Config, Elapsed_Time, Reply_Timeout, Node, Connection_Id, Query_Request) ->
    %% Self cannot be executed inside the fun(), it needs to be set in the current context.
    Self = self(),
    Worker_Reply_Ref = make_ref(),
    %% Avoiding export of exec_pending_request/5
    Worker_Fun = fun() -> exec_pending_request(Worker_Reply_Ref, Self, Node, Connection_Id, Query_Request) end,
    {Worker_Pid, Worker_Monitor_Ref} = spawn_opt(Worker_Fun, [monitor]),   % May want to add other options
    Timeout_Remaining = Reply_Timeout - (Elapsed_Time div 1000),
    try   receive_worker_reply(Config, Worker_Reply_Ref, Timeout_Remaining, Worker_Pid, Worker_Monitor_Ref)
    after erlang:demonitor(Worker_Monitor_Ref, [flush])
    end.

-spec insert_audit_counts(audit_ets_name()) -> true.
%% @doc Insert audit_serial_counts record to audit ets table hold error increments.
insert_audit_counts(Audit_Name) ->
    Count_Rec = #audit_serial_counts{count_type_key=?COUNTS_KEY},
    true = ets:insert_new(Audit_Name, Count_Rec).

-spec status(config_type()) -> status_reply().
%% @doc Get the current queue size of the pending queue.
status(Config) -> elysium_buffering_strategy:status(Config).


%%%-----------------------------------------------------------------------
%%% Internal support functions
%%%-----------------------------------------------------------------------

%% Internal loop function to retry getting from the queue.
fetch_pid_from_queue(_Config, _Session_Queue, Max_Retries, Times_Tried)
  when Times_Tried >= Max_Retries ->
    none_available;
fetch_pid_from_queue(Config, Session_Queue, Max_Retries, Times_Tried) ->
    case elysium_serial_queue:checkout(Session_Queue) of
        empty -> none_available;

        %% Return only a live pid, otherwise get the next one.
        {value, {_Node, Session_Id} = Session_Data} when is_pid(Session_Id) ->
            case is_process_alive(Session_Id) of
                %% NOTE: we toss only MAX_CHECKOUT_RETRY dead pids
                false -> _ = audit_count(Config, session_dead),
                         fetch_pid_from_queue(Config, Session_Queue, Max_Retries, Times_Tried+1);
                true  -> _ = elysium_buffering_audit:audit_data_checkout(Config, ?MODULE, Session_Id),
                         Session_Data
            end
    end.

wait_for_session(Config, Pending_Queue, Sid_Reply_Ref, Start_Time, Query_Request, Reply_Timeout) ->
    Session_Queue = elysium_config:session_queue_name(Config),
    case fetch_pid_from_queue(Config, Session_Queue, 1, 0) of

        %% A free connection showed up since we first checked...
        {Node, Session_Id} when is_pid(Session_Id) ->
            case is_process_alive(Session_Id) of
                true  -> handle_pending_request(Config, 0, Reply_Timeout, Node, Session_Id, Query_Request);
                false -> _ = audit_count(Config, session_dead),
                         wait_for_session(Config, Pending_Queue, Sid_Reply_Ref,
                                          Start_Time, Query_Request, Reply_Timeout)
            end;

        %% None are still available, queue the request and wait for one to free up.
        none_available ->
            _Pending_Count = elysium_serial_queue:checkin(Pending_Queue, {{self(), Sid_Reply_Ref}, Start_Time}),
            wait_for_session_loop(Config, Pending_Queue, Sid_Reply_Ref, Start_Time, Query_Request, Reply_Timeout)
    end.

wait_for_session_loop(Config, Pending_Queue, Sid_Reply_Ref, Start_Time, Query_Request, Reply_Timeout) ->
    receive
        %% A live elysium session channel is now available to make the request...
        {sid, Sid_Reply_Ref, Node, Session_Id, Pending_Queue, Is_New_Connection} ->
            Elapsed_Time = timer:now_diff(os:timestamp(), Start_Time),
            case {Elapsed_Time >= Reply_Timeout * 1000, is_process_alive(Session_Id)} of

                %% Alas, we timed out waiting...
                {true,  true}  -> _ = audit_count(Config, session_timeouts),
                                  _ = checkin_connection(Config, Node, Session_Id, Is_New_Connection),
                                  {wait_for_session_timeout, Reply_Timeout};
                {true,  false} -> _ = audit_count(Config, session_dead),
                                  _ = audit_count(Config, session_timeouts),
                                  {wait_for_session_timeout, Reply_Timeout};

                %% Dead session, loop waiting for another (hopefully live) connection to free up...
                {false, false} -> _ = audit_count(Config, session_dead),
                                  New_Timeout = Reply_Timeout - (Elapsed_Time div 1000),
                                  wait_for_session(Config, Pending_Queue, Sid_Reply_Ref,
                                                   Start_Time, Query_Request, New_Timeout);

                %% Get some results while we still have time!
                {false, true}  -> handle_pending_request(Config, Elapsed_Time, Reply_Timeout,
                                                         Node, Session_Id, Query_Request)
            end;

        %% Previous timed out request sent a Session_Id late, check it in and wait for our expected one.
        {sid, _, Node, Session_Id, Pending_Queue, Is_New_Connection} ->
            _ = audit_count(Config, session_wrong),
            _ = case is_process_alive(Session_Id) of
                    false -> audit_count(Config, session_dead);
                    true  -> checkin_immediate(Config, Node, Session_Id, Pending_Queue, Is_New_Connection)
                end,
            Elapsed_Time = timer:now_diff(os:timestamp(), Start_Time),
            case Elapsed_Time >= Reply_Timeout * 1000 of
                true -> _ = audit_count(Config, session_timeouts),
                        {wait_for_session_timeout, Reply_Timeout};
                false -> New_Timeout = Reply_Timeout - (Elapsed_Time div 1000),
                         wait_for_session_loop(Config, Pending_Queue, Sid_Reply_Ref, Start_Time,
                                               Query_Request, New_Timeout)
            end

        %% Any other messages are intended for the blocked caller, leave them in the message queue.

    after Reply_Timeout ->
            %% Handle race condition messaging vs timeout waiting for message.
            erlang:yield(),
            _ = receive
                    {sid, Sid_Reply_Ref, Node, Session_Id, Pending_Queue, Is_New_Connection} ->
                        case is_process_alive(Session_Id) of
                            false -> audit_count(Config, session_dead);
                            true  -> checkin_connection(Config, Node, Session_Id, Is_New_Connection)
                        end
                after 0 -> no_msgs
                end,
            _ = audit_count(Config, session_timeouts),
            {wait_for_session_timeout, Reply_Timeout}
    end.

%% Worker_Pid is passed to allow tracing
receive_worker_reply(Config, Worker_Reply_Ref, Timeout_Remaining, Worker_Pid, Worker_Monitor_Ref) ->
    receive
        {wrr, Worker_Reply_Ref, Reply} -> Reply;
        {'DOWN', Worker_Monitor_Ref, process, Worker_Pid, Reason} ->
            _ = audit_count(Config, worker_errors),
            {worker_reply_error, Reason}
    after Timeout_Remaining ->
            _ = audit_count(Config, worker_timeouts),
            {worker_reply_timeout, Timeout_Remaining}
    end.

-spec checkin_immediate(config_type(), {Ip::string(), Port::pos_integer()},
                        Session_Id::pid(), Pending_Queue::requests_queue_name(), Is_New_Connection::boolean())
                       -> {boolean(), {connection_queue_name(), Idle_Count, Max_Count}}
                              when Idle_Count :: max_connections(),
                                   Max_Count  :: max_connections().
%% @doc
%%   Checkin a seestar_session by putting it at the end of the
%%   available connection queue. Returns whether the checkin was
%%   successful (it fails if the process is dead when checkin is
%%   attempted), and how many connections are available after the
%%   checkin.
%%
%%   Sessions have a fixed probability of failure on checkin.
%%   The decay probability is a number of chances of dying per
%%   1 Billion checkin attempts. If the session is killed, it
%%   will be replaced by the supervisor automatically spawning
%%   a new worker and placing it at the end of the queue.
%%
%%   The configuration parameter is not validated because this
%%   function should be a hotspot and we don't want it to slow
%%   down or become a concurrency bottleneck.
%% @end
checkin_immediate(Config, Node, Session_Id, Pending_Queue, true) ->
    Session_Queue = elysium_config:session_queue_name (Config),
    Max_Sessions  = elysium_config:session_max_count  (Config),
    case is_process_alive(Session_Id) of
        false -> _ = audit_count(Config, session_dead),
                 fail_checkin(Session_Queue, Max_Sessions, {Node, Session_Id}, Config);
        true  -> succ_checkin(Session_Queue, Max_Sessions, {Node, Session_Id}, Config, Pending_Queue, true)
    end;
checkin_immediate(Config, Node, Session_Id, Pending_Queue, false) ->
    Session_Queue = elysium_config:session_queue_name (Config),
    Max_Sessions  = elysium_config:session_max_count  (Config),
    case is_process_alive(Session_Id) of
        false -> _ = audit_count(Config, session_dead),
                 fail_checkin(Session_Queue, Max_Sessions, {Node, Session_Id}, Config);
        true  -> case elysium_buffering_strategy:decay_causes_death(Config, Session_Id) of
                     false -> succ_checkin(Session_Queue, Max_Sessions, {Node, Session_Id},
                                           Config, Pending_Queue, false);
                     true  -> _ = elysium_buffering_strategy:decay_connection(Config, ?MODULE, Session_Id),
                              fail_checkin(Session_Queue, Max_Sessions, {Node, Session_Id}, Config)
                  end
    end.

%% Session_Data is passed to allow tracing
fail_checkin(Session_Queue, Max_Sessions, {_Node, Session_Id}, Config) ->
    _ = elysium_buffering_audit:audit_data_delete(Config, ?MODULE, Session_Id),
    Available = elysium_serial_queue:num_entries(Session_Queue),
    {false, elysium_buffering_strategy:report_available_resources(Session_Queue, Available, Max_Sessions)}.

succ_checkin(Session_Queue, Max_Sessions, {Node, Session_Id} = Session_Data,
             Config, Pending_Queue, Is_New_Connection) ->
    case elysium_serial_queue:is_empty(Pending_Queue) of
        false -> checkin_pending(Config, Node, Session_Id, Pending_Queue, Is_New_Connection);
        true  ->
            Available = checkin_session(Session_Queue, Session_Data),
            _ = elysium_buffering_audit:audit_data_checkin(Config, ?MODULE, Session_Id),
            {true, elysium_buffering_strategy:report_available_resources(Session_Queue, Available, Max_Sessions)}
    end.

checkin_session(Session_Queue, Session_Data) ->
    elysium_serial_queue:checkin(Session_Queue, Session_Data).

delay_checkin(Config) ->
    Session_Queue = elysium_config:session_queue_name  (Config),
    Max_Sessions  = elysium_config:session_max_count   (Config),
    Available     = elysium_serial_queue:num_entries (Session_Queue),
    {pending, elysium_buffering_strategy:report_available_resources(Session_Queue, Available, Max_Sessions)}.

checkin_pending(Config, Node, Sid, Pending_Queue, Is_New_Connection) ->
    case elysium_serial_queue:checkout(Pending_Queue) of

        %% There are no pending requests, return the session...
        empty -> checkin_immediate(Config, Node, Sid, Pending_Queue, Is_New_Connection);

        %% Got a pending request, let's run it...
        {value, {{Waiting_Pid, Sid_Reply_Ref}, When_Originally_Queued}} ->

            Reply_Timeout = elysium_config:request_reply_timeout(Config),
            case timer:now_diff(os:timestamp(), When_Originally_Queued) of

                %% Too much time has passed, skip this request and try another...
                Expired when Expired > Reply_Timeout * 1000 ->
                    _ = audit_count(Config, pending_timeouts),
                    checkin_pending(Config, Node, Sid, Pending_Queue, Is_New_Connection);

                %% There's still time to reply, run the request if the session is still alive.
                _Remaining_Time ->
                    case is_process_alive(Waiting_Pid) of
                        false -> _ = audit_count(Config, pending_dead),
                                 checkin_pending(Config, Node, Sid, Pending_Queue, Is_New_Connection);
                        true  -> Waiting_Pid ! {sid, Sid_Reply_Ref, Node, Sid, Pending_Queue, Is_New_Connection},
                                 _ = elysium_buffering_audit:audit_data_pending(Config, ?MODULE, Sid),
                                 delay_checkin(Config)
                    end
            end
    end.

%% Watch Out! This function swaps from the Config on a checkin request to the
%% Config on the original pending query. If you somehow mix connection queues
%% by passing different Configs, the clusters which queries run on may get
%% mixed up resulting in queries/updates/deletes talking to the wrong clusters.
exec_pending_request(Reply_Ref, Reply_Pid, Node, Sid, {bare_fun, Config, Query_Fun, Args, Consistency}) ->
    try   Reply = Query_Fun(Sid, Args, Consistency),
          Reply_Pid ! {wrr, Reply_Ref, Reply}
    catch A:B -> lager:error("Query execution caught ~p:~p for ~p ~p ~9999p~n",
                             [A,B, Reply_Pid, Args, erlang:get_stacktrace()])
    after _ = checkin_connection(Config, Node, Sid, false)
    end;
exec_pending_request(Reply_Ref, Reply_Pid, Node, Sid, {mod_fun,  Config, Mod,  Fun, Args, Consistency}) ->
    try   Reply = Mod:Fun(Sid, Args, Consistency),
          Reply_Pid ! {wrr, Reply_Ref, Reply}
    catch A:B -> lager:error("Query execution caught ~p:~p for ~p ~p ~9999p~n",
                             [A,B, Reply_Pid, Args, erlang:get_stacktrace()])
    after _ = checkin_connection(Config, Node, Sid, false)
    end.

%% Internal auditing functions
audit_count(Config, Type) ->
    Audit_Key   = {?MODULE, counts},
    Audit_Name  = elysium_config:audit_ets_name(Config),
    Counter_Pos = case Type of
                      pending_dead          -> #audit_serial_counts.pending_dead;
                      pending_timeouts      -> #audit_serial_counts.pending_timeouts;
                      session_dead          -> #audit_serial_counts.session_dead;
                      session_decay         -> #audit_serial_counts.session_decay;
                      session_timeouts      -> #audit_serial_counts.session_timeouts;
                      session_wrong         -> #audit_serial_counts.session_wrong;
                      worker_errors         -> #audit_serial_counts.worker_errors;
                      worker_timeouts       -> #audit_serial_counts.worker_timeouts
                  end,
    ets:update_counter(Audit_Name, Audit_Key, {Counter_Pos, 1}).

