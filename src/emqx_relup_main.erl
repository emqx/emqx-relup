-module(emqx_relup_main).

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
    RootDir = code:root_dir(),
    CurrVsn = emqx_release:version(),
    case emqx_relup_handler:check_upgrade(TargetVsn, RootDir) of
        {error, Reason} ->
            ?PRINT("[ERROR] check upgrade failed, reason: ~p", [Reason]),
            {error, Reason};
        {ok, UnpackDir} ->
            ?PRINT("[INFO] hot upgrading emqx from current version: ~p to target version: ~p",
                [CurrVsn, TargetVsn]),
            try emqx_relup_handler:perform_upgrade(TargetVsn, RootDir, UnpackDir) of
                ok ->
                    case emqx_relup_handler:permanent_upgrade(TargetVsn, RootDir, UnpackDir) of
                        ok ->
                            ?PRINT("[INFO] successfully upgraded emqx to target version: ~p", [TargetVsn]),
                            ok;
                        {error, Reason} ->
                            ?PRINT("[ERROR] permanent release failed, reason: ~p", [Reason]),
                            {error, Reason}
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
