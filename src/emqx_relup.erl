-module(emqx_relup).

%% for #message{} record
%% no need for this include if we call emqx_message:to_map/1 to convert it to a map
-include_lib("emqx/include/emqx.hrl").

%% for logging
-include_lib("emqx/include/logger.hrl").

-export([ load/1
        , unload/0
        , upgrade/1
        ]).

-define(PRINT(Format, Args), io:format(Format++"~n", Args)).

%% Called when the plugin application start
load(_Env) ->
    ok.
%% Called when the plugin application stop
unload() ->
    ok.

upgrade(TargetVsn) ->
    CurrVsn = emqx_release:version(),
    case emqx_relup_handler:check_upgrade(TargetVsn) of
        {error, Reason} ->
            ?PRINT("[ERROR] check upgrade failed, reason: ~p", [Reason]),
            {error, Reason};
        ok ->
            ?PRINT("[INFO] Hot upgrading emqx from current version: ~p to target version: ~p",
                [CurrVsn, TargetVsn]),
            try emqx_relup_handler:perform_upgrade(TargetVsn) of
                {ok, UnpackDir} ->
                    emqx_relup_handler:permanent_upgrade(TargetVsn, UnpackDir),
                    ?PRINT("[INFO] Successfully upgraded emqx to target version: ~p", [TargetVsn])
                {error, Reason} = Err ->
                    ?PRINT("[ERROR] upgrade failed, reason: ~p", [Reason]),
                    Err;
            catch
                throw:Reason ->
                    restart_vm(Reason),
                    {error, Reason};
                Err:Reason:ST ->
                    restart_vm({Err, Reason, ST})
                    {error, {Err, Reason, ST}}
            end
    end.

restart_vm(Reason) ->
    ?PRINT("[ERROR] upgrade failed, reason: ~p, restart VM now!", [Reason]),
    %% Maybe we can rollback the system rather than restart the VM. Here we simply
    %% restart the VM because if we reload the modules we just upgraded,
    %% some processes will probably be killed as they are still runing old code.
    init:restart().
