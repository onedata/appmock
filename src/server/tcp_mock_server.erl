%%%-------------------------------------------------------------------
%%% @author Lukasz Opiola
%%% @copyright (C) 2015 ACK CYFRONET AGH
%%% This software is released under the MIT license
%%% cited in 'LICENSE.txt'.
%%% @end
%%%-------------------------------------------------------------------
%%% @doc
%%% This gen_server provides following functionalities:
%%% - loading TCP server mocks from description module
%%% - starting and stopping ranch listeners
%%% - in-memory persistence for state such as history of received packets.
%%% @end
%%%-------------------------------------------------------------------
-module(tcp_mock_server).
-author("Lukasz Opiola").

-behaviour(gen_server).

-include("appmock_internal.hrl").
-include_lib("ctool/include/logging.hrl").

%% API
-export([start_link/0, healthcheck/0]).
-export([report_connection_state/3, register_packet/2]).
-export([tcp_server_specific_message_count/2, tcp_server_all_messages_count/1, tcp_server_send/3]).
-export([tcp_mock_history/1, reset_tcp_mock_history/0, tcp_server_connection_count/1]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).
% Number of acceptors in ranch listeners
-define(NUMBER_OF_ACCEPTORS, 10).
% Timeout of tcp_server_send function - if by this time all connection pids do not report
% back, the sending is considered failed.
-define(SEND_TIMEOUT_BASE, timer:seconds(10)).
-define(SEND_TIMEOUT_PER_MSG, timer:seconds(1)).

% Internal state of the gen server
-record(state, {
    listeners = [] :: [term()],
    history_enabled = [] :: [{Port :: integer(), Flag :: boolean()}],
    port_msg_counts = [] :: [{Port :: integer(), Count :: integer()}],
    % The history dict holds mappings Packet -> integer(), where the
    % integer value means number of such packets received.
    port_msg_counts_per_msg = [] :: [{Port :: integer(), CountPerMsgMap :: dict:dict()}],
    inititial_port_msg_counts_per_msg = [] :: [{Port :: integer(), CountPerMsgMap :: dict:dict()}],
    % Complete message history for given port (NOTE: in reverse order!)
    port_msg_history = [] :: [{Port :: integer(), [binary()]}],
    % The connections proplist holds a list of active pids for each port.
    connections = [] :: [{Port :: integer(), [pid()]}]
}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%%--------------------------------------------------------------------
%% @doc
%% Should check if this gen_server and all underlying services (like cowboy listeners)
%% are ready and working properly. If any error occurs, it should be logged inside this function.
%% @end
%%--------------------------------------------------------------------
-spec healthcheck() -> ok | error.
healthcheck() ->
    {ok, Timeout} = application:get_env(?APP_NAME, nagios_healthcheck_timeout),
    gen_server:call(?SERVER, healthcheck, Timeout).


%%--------------------------------------------------------------------
%% @doc
%% Called from connection pids to register and unregister a connection. Thanks to this,
%% this server can easily order the pids to send some data to clients.
%% @end
%%--------------------------------------------------------------------
-spec report_connection_state(Port :: integer(), Pid :: pid(), IsAlive :: boolean()) -> ok.
report_connection_state(Port, Pid, IsAlive) ->
    gen_server:call(?SERVER, {report_connection_state, Port, Pid, IsAlive}).


%%--------------------------------------------------------------------
%% @doc
%% Saves in history that a certain packet has been received on given port.
%% @end
%%--------------------------------------------------------------------
-spec register_packet(Port :: integer(), Data :: binary()) -> ok.
register_packet(Port, Data) ->
    gen_server:call(?SERVER, {register_packet, Port, Data}).


%%--------------------------------------------------------------------
%% @doc
%% Returns how many times has a TCP server received specific message.
%% @end
%%--------------------------------------------------------------------
-spec tcp_server_specific_message_count(Port :: integer(), Data :: binary()) -> {ok, integer()} | {error, term()}.
tcp_server_specific_message_count(Port, Data) ->
    gen_server:call(?SERVER, {tcp_server_specific_message_count, Port, Data}).


%%--------------------------------------------------------------------
%% @doc
%% Returns the total number of messages that a TCP endpoint received.
%% @end
%%--------------------------------------------------------------------
-spec tcp_server_all_messages_count(Port :: integer()) -> {ok, integer()} | {error, term()}.
tcp_server_all_messages_count(Port) ->
    gen_server:call(?SERVER, {tcp_server_all_messages_count, Port}).


%%--------------------------------------------------------------------
%% @doc
%% Sends given data to all clients connected to the TCP server on specified port.
%% @end
%%--------------------------------------------------------------------
-spec tcp_server_send(Port :: integer(), Data :: binary(), Count :: integer()) -> true | {error, term()}.
tcp_server_send(Port, Data, Count) ->
    gen_server:call(?SERVER, {tcp_server_send, Port, Data, Count}, infinity).


%%--------------------------------------------------------------------
%% @doc
%% Returns full history of messages received on given endpoint.
%% @end
%%--------------------------------------------------------------------
-spec tcp_mock_history(Port :: integer()) -> {ok, [Message :: binary()]} | {error, term()}.
tcp_mock_history(Port) ->
    gen_server:call(?SERVER, {tcp_mock_history, Port}, infinity).


%%--------------------------------------------------------------------
%% @doc
%% Handles requests to reset ALL mocked TCP endpoints.
%% @end
%%--------------------------------------------------------------------
-spec reset_tcp_mock_history() -> true.
reset_tcp_mock_history() ->
    gen_server:call(?SERVER, reset_tcp_mock_history).


%%--------------------------------------------------------------------
%% @doc
%% Handles requests to check how many clients are connected to given endpoint.
%% @end
%%--------------------------------------------------------------------
-spec tcp_server_connection_count(Port :: integer()) -> {ok, integer()} | {error, term()}.
tcp_server_connection_count(Port) ->
    gen_server:call(?SERVER, {tcp_server_connection_count, Port}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the appmock application by creating an ETS table, initializing records in it,
%% loading given mock app description module and starting cowboy listenera.
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    {ok, AppDescriptionFile} = application:get_env(?APP_NAME, app_description_file),
    DescriptionModule = appmock_utils:load_description_module(AppDescriptionFile),
    {ListenersIDs, Ports, HistoryEnabled} = start_listeners(DescriptionModule),
    InitializedHistory = lists:map(
        fun(Port) ->
            {Port, dict:new()}
        end, Ports),
    InitializedConnections = lists:map(
        fun(Port) ->
            {Port, []}
        end, Ports),
    {ok, #state{listeners = ListenersIDs, connections = InitializedConnections, port_msg_counts = [],
        port_msg_counts_per_msg = InitializedHistory, inititial_port_msg_counts_per_msg = InitializedHistory,
        port_msg_history = [], history_enabled = HistoryEnabled}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call(healthcheck, _From, #state{port_msg_counts_per_msg = CountsPerMsg} = State) ->
    Reply =
        try
            % Check connectivity to all TCP listeners
            lists:foreach(
                fun({Port, _}) ->
                    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, []),
                    gen_tcp:close(Socket)
                end, CountsPerMsg),
            ok
        catch T:M ->
            ?error_stacktrace("Error during ~p healthcheck- ~p:~p", [?MODULE, T, M]),
            error
        end,
    {reply, Reply, State};


handle_call({report_connection_state, Port, Pid, IsAlive}, _From, State) ->
    #state{connections = Connections} = State,
    ConnectionsForPort = proplists:get_value(Port, Connections, []),
    NewConnectionsForPort = case IsAlive of
                                true -> [Pid | ConnectionsForPort];
                                false -> lists:delete(Pid, ConnectionsForPort)
                            end,
    NewConnections = [{Port, NewConnectionsForPort} | proplists:delete(Port, Connections)],
    {reply, ok, State#state{connections = NewConnections}};


handle_call({register_packet, Port, Data}, _From, State) ->
    #state{port_msg_counts_per_msg = CountsPerMsg, port_msg_counts = RequestCount,
        port_msg_history = MsgHistory, history_enabled = HistoryEnabled} = State,
    {NewCountsPerMsg, NewMsgHistory} =
        case proplists:get_value(Port, HistoryEnabled, true) of
            false ->
                {CountsPerMsg, MsgHistory};
            true ->
                CountsForPort = proplists:get_value(Port, CountsPerMsg, dict:new()),
                NewCountsForPort = dict:update(Data, fun([Old]) ->
                    [Old + 1] end, [1], CountsForPort),
                NCPR = [{Port, NewCountsForPort} | proplists:delete(Port, CountsPerMsg)],
                HistoryForPort = proplists:get_value(Port, MsgHistory, []),
                NewHistoryForPort = [Data | HistoryForPort],
                NWH = [{Port, NewHistoryForPort} | proplists:delete(Port, MsgHistory)],
                {NCPR, NWH}
        end,
    CountForPort = proplists:get_value(Port, RequestCount, 0),
    NewCounts = [{Port, CountForPort + 1} | proplists:delete(Port, RequestCount)],
    {reply, ok, State#state{port_msg_counts_per_msg = NewCountsPerMsg,
        port_msg_history = NewMsgHistory, port_msg_counts = NewCounts}};

handle_call({tcp_server_specific_message_count, Port, Data}, _From, State) ->
    #state{port_msg_counts_per_msg = CountsPerMsg, history_enabled = HistoryEnabled} = State,
    Reply = case proplists:get_value(Port, HistoryEnabled, true) of
                false ->
                    {error, counter_mode};
                true ->
                    CountsForPort = proplists:get_value(Port, CountsPerMsg, undefined),
                    case CountsForPort of
                        undefined ->
                            {error, wrong_endpoint};
                        _ ->
                            case dict:find(Data, CountsForPort) of
                                {ok, [Count]} ->
                                    {ok, Count};
                                error ->
                                    {ok, 0}
                            end
                    end
            end,
    {reply, Reply, State};

handle_call({tcp_server_all_messages_count, Port}, _From, #state{port_msg_counts = RequestCount} = State) ->
    CountForPort = proplists:get_value(Port, RequestCount, 0),
    {reply, {ok, CountForPort}, State};

handle_call({tcp_server_send, Port, Data, Count}, _From, State) ->
    #state{connections = Connections} = State,
    ConnectionsForPort = proplists:get_value(Port, Connections, undefined),
    Reply = case ConnectionsForPort of
                undefined ->
                    {error, wrong_endpoint};
                _ ->
                    Timeout = ?SEND_TIMEOUT_BASE + Count * ?SEND_TIMEOUT_PER_MSG,
                    Result = utils:pmap(
                        fun(Pid) ->
                            Pid ! {self(), send, Data, Count},
                            receive
                                {Pid, ok} -> ok
                            after
                                Timeout -> error
                            end
                        end, ConnectionsForPort),
                    % If all pids reported back, sending succeded
                    case lists:duplicate(length(Result), ok) of
                        Result ->
                            true;
                        SomethingElse ->
                            ?error("failed_to_send_data: ~p", [SomethingElse]),
                            {error, failed_to_send_data}
                    end
            end,

    {reply, Reply, State};

handle_call({tcp_mock_history, Port}, _From, State) ->
    #state{port_msg_history = PortMsgHistory, history_enabled = HistoryEnabled} = State,
    Reply = case proplists:get_value(Port, HistoryEnabled, true) of
                false ->
                    {error, counter_mode};
                true ->
                    HistoryForPort = proplists:get_value(Port, PortMsgHistory, []),
                    {ok, lists:reverse(HistoryForPort)}
            end,
    {reply, Reply, State};

handle_call(reset_tcp_mock_history, _From, State) ->
    #state{inititial_port_msg_counts_per_msg = InitialRequestHistory} = State,
    {reply, true, State#state{port_msg_counts_per_msg = InitialRequestHistory,
        port_msg_counts = [], port_msg_history = []}};

handle_call({tcp_server_connection_count, Port}, _From, State) ->
    #state{connections = Connections} = State,
    ConnectionsForPort = proplists:get_value(Port, Connections, undefined),
    Reply = case ConnectionsForPort of
                undefined ->
                    {error, wrong_endpoint};
                _ ->
                    {ok, length(ConnectionsForPort)}
            end,
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% Cleans up by stopping previously started cowboy listeners and deleting the ETS table.
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, #state{listeners = Listeners}) ->
    % Stop all previously started ranch listeners
    lists:foreach(
        fun(Listener) ->
            ?info("Stopping ranch listener: ~p", [Listener]),
            ranch:stop_listener(Listener)
        end, Listeners),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Starts all TCP servers that were specified in the app description module.
%% Returns a list of lsitener IDs and a list of ports on which servers have been started.
%% @end
%%--------------------------------------------------------------------
-spec start_listeners(AppDescriptionModule :: module()) ->
    {ListenerIDs :: [term()], Ports :: [integer()], HistoryEnabled :: [{Port :: integer(), Flag :: boolean()}]}.
start_listeners(AppDescriptionModule) ->
    TCPServerMocks = AppDescriptionModule:tcp_server_mocks(),
    ListenerIDsAndPortsAndHistory = lists:map(
        fun(#tcp_server_mock{port = Port, ssl = UseSSL, packet = Packet, type = Type}) ->
            % Generate listener name
            ListenerID = "tcp" ++ integer_to_list(Port),
            Protocol = case UseSSL of
                           true -> ranch_ssl2;
                           false -> ranch_tcp
                       end,
            Opts = case UseSSL of
                       true ->
                           {ok, CaCertFile} = application:get_env(?APP_NAME, ca_cert_file),
                           {ok, CertFile} = application:get_env(?APP_NAME, cert_file),
                           {ok, KeyFile} = application:get_env(?APP_NAME, key_file),
                           [
                               {port, Port},
                               {cacertfile, CaCertFile},
                               {certfile, CertFile},
                               {keyfile, KeyFile}
                           ];
                       false ->
                           [{port, Port}]
                   end,
            {ok, _} = ranch:start_listener(ListenerID, ?NUMBER_OF_ACCEPTORS,
                Protocol, Opts, tcp_mock_handler, [Port, Packet]),
            HistoryEnabled = case Type of history -> true; _ -> false end,
            {ListenerID, Port, HistoryEnabled}
        end, TCPServerMocks),
    {ListenerIDs, Ports, HistoryEnabledList} = lists:unzip3(ListenerIDsAndPortsAndHistory),
    {ListenerIDs, Ports, lists:zip(Ports, HistoryEnabledList)}.
