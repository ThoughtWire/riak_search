%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(qilr_analyzer).

-behaviour(gen_server).

-include("analysis_pb.hrl").

-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/0, analyze/2, analyze/3, analyze/4, close/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {socket,
                caller}).

analyze(Pid, Text) when is_list(Text) ->
    case analyze(Pid, list_to_binary(Text)) of
        {ok, Tokens} ->
            {ok, [binary_to_list(Token) || Token <- Tokens]};
        Error ->
            Error
    end;
analyze(Pid, Text) when is_binary(Text) ->
    analyze(Pid, Text, undefined).

analyze(Pid, Text, AnalyzerFactory) when is_list(Text) ->
    analyze(Pid, list_to_binary(Text), AnalyzerFactory);
analyze(Pid, Text, AnalyzerFactory) ->
    analyze(Pid, Text, AnalyzerFactory, undefined).

analyze(Pid, Text, AnalyzerFactory, AnalyzerArgs) ->
    try
        Req = #analysisrequest{text=Text, analyzer_factory=AnalyzerFactory, 
                               analyzer_args=AnalyzerArgs},
        case gen_server:call(Pid, {analyze, Req}, 10000) of
            ignore ->
                analyze(Pid, Text, AnalyzerFactory);
        R ->
            R
        end
    catch
        exit:{timeout, {gen_server,call, _Call}} -> % gen_server timeout
            exit(Pid, kill), % pool will re-open so nobody gets a stale analyzer
            timeout
    end.

close(Pid) ->
    gen_server:call(Pid, close).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    case application:get_env(qilr, analysis_port) of
        {ok, Port} when is_integer(Port) ->
            case service_connect(Port) of
                {ok, Sock} ->
                    {ok, #state{socket=Sock}};
                Error ->
                    error_logger:error_msg("Error connecting to analysis server: ~p", [Error]),
                    {stop, Error}
            end;
        _ ->
            {stop, {error, bad_analysis_port}}
    end.

handle_call(close, _From, #state{socket=Sock}=State) ->
    gen_tcp:close(Sock),
    {stop, normal, ok, State};

handle_call({analyze, Req}, From, #state{socket=Sock, caller=undefined}=State) ->
    gen_tcp:send(Sock, analysis_pb:encode_analysisrequest(Req)),
    inet:setopts(Sock, [{active, once}]),
    {noreply, State#state{caller=From}};

handle_call(_Request, _From, State) ->
    {reply, ignore, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, _Sock, Data}, #state{caller=Caller}=State) ->
    Res = analysis_pb:decode_analysisresult(Data),
    gen_server:reply(Caller, {ok, parse_results(Res#analysisresult.token)}),
    {noreply, State#state{caller=undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
service_connect(Port) ->
    gen_tcp:connect("127.0.0.1", Port, [binary, {active, once},
                                        {packet, 4},
                                        {linger, {true, 0}},
                                        {nodelay, true}], 1000).

parse_results([0]) ->
    [];
parse_results(Results) ->
    F = fun(C, {Curr, Acc}) ->
                if
                    C == 0 ->
                        case Curr of
                            [] ->
                                {Curr, Acc};
                            _ ->
                                {[], [list_to_binary(Curr)|Acc]}
                        end;
                    true ->
                        {[C|Curr], Acc}
                end end,
    {First, Rest} = lists:foldr(F, {[], []}, Results),
    case Rest of
        [] ->
            case First of
                [] ->
                    [];
                _ ->
                    [list_to_binary(First)]
            end;
        _ ->
            [list_to_binary(First)|Rest]
    end.
