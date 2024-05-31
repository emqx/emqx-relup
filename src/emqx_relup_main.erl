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

-define(LOG(LEVEL, MSG), logger:log(LEVEL, (MSG)#{tag => "RELUP"})).

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
            ?LOG(error, #{msg => check_upgrade_failed, reason => Reason}),
            {error, Reason};
        {ok, Opts1} ->
            ?LOG(notice, #{msg => perform_upgrade, from_vsn => CurrVsn, target_vsn => TargetVsn}),
            try emqx_relup_handler:perform_upgrade(CurrVsn, TargetVsn, RootDir, Opts1) of
                ok ->
                    case emqx_relup_handler:permanent_upgrade(CurrVsn, TargetVsn, RootDir, Opts1) of
                        ok ->
                            ?LOG(notice, #{msg => upgrade_complete, from_vsn => CurrVsn, target_vsn => TargetVsn}),
                            ok;
                        {error, Reason} = Err ->
                            ?LOG(error, #{msg => permanent_upgrade_failed, reason => Reason, from_vsn => CurrVsn, target_vsn => TargetVsn}),
                            Err
                    end;
                {error, Reason} = Err ->
                    ?LOG(error, #{msg => perform_upgrade_failed, reason => Reason, from_vsn => CurrVsn, target_vsn => TargetVsn}),
                    Err
            catch
                throw:Reason ->
                    restart_vm(Reason);
                Err:Reason:ST ->
                    restart_vm({Err, Reason, ST})
            end
    end.

restart_vm(Reason) ->
    ?LOG(error, #{msg => restart_vm, reason => Reason}),
    %% Maybe we can rollback the system rather than restart the VM. Here we simply
    %% restart the VM because if we reload the modules we just upgraded,
    %% some processes will probably be killed as they are still runing old code.
    init:restart(),
    {error_vm_restarted, Reason}.
