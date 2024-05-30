-module(emqx_relup_main).

-behaviour(gen_server).

-export([ start_link/0
        , init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        ]).

-export([ load/1
        , unload/0
        , upgrade/1
        , upgrade/2
        ]).

-type state() :: #{}.

-define(PRINT(Format, Args), io:format(Format++"~n", Args)).

%%==============================================================================
%% API
%%==============================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

upgrade(TargetVsn) ->
    upgrade(TargetVsn, #{deploy_inplace => false}).

upgrade(TargetVsn, Opts) ->
    gen_server:call(?MODULE, {upgrade, TargetVsn, Opts}, infinity).

%% Called when the plugin application start
load(_Env) ->
    ok.
%% Called when the plugin application stop
unload() ->
    ok.

%%==============================================================================
%% gen_server callbacks
%%==============================================================================
-spec init(list()) -> {ok, state()}.
init([]) ->
    {ok, #{}}.

handle_call({upgrade, TargetVsn, Opts}, _From, State) ->
    Reply = do_upgrade(emqx_release:version(), TargetVsn, code:root_dir(), Opts),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

do_upgrade(CurrVsn, TargetVsn, RootDir, Opts) ->
    case emqx_relup_handler:check_and_unpack(CurrVsn, TargetVsn, RootDir, Opts) of
        {error, Reason} ->
            ?PRINT("[ERROR] check upgrade failed, reason: ~p", [Reason]),
            {error, Reason};
        {ok, Opts1} ->
            ?PRINT("[INFO] hot upgrading emqx from current version: ~p to target version: ~p",
                [CurrVsn, TargetVsn]),
            try emqx_relup_handler:perform_upgrade(CurrVsn, TargetVsn, RootDir, Opts1) of
                ok ->
                    case emqx_relup_handler:permanent_upgrade(CurrVsn, TargetVsn, RootDir, Opts1) of
                        ok ->
                            ?PRINT("[INFO] successfully upgraded emqx to target version: ~p", [TargetVsn]),
                            ok;
                        {error, Reason} = Err ->
                            ?PRINT("[ERROR] permanent release failed, reason: ~p", [Reason]),
                            Err
                    end;
                {error, Reason} = Err ->
                    ?PRINT("[ERROR] perform upgrade failed, reason: ~p", [Reason]),
                    Err
            catch
                throw:Reason ->
                    restart_vm(Reason),
                    {error, Reason};
                Err:Reason:ST ->
                    restart_vm({Err, Reason, ST}),
                    {error, {Err, Reason, ST}}
            end
    end.

restart_vm(Reason) ->
    ?PRINT("[ERROR] upgrade failed, restart VM now! Reason: ~p", [Reason]),
    %% Maybe we can rollback the system rather than restart the VM. Here we simply
    %% restart the VM because if we reload the modules we just upgraded,
    %% some processes will probably be killed as they are still runing old code.
    init:restart().
