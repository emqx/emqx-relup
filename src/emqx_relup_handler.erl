-module(emqx_relup_handler).

-behaviour(gen_server).

-export([ start_link/0
        , init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        ]).

-export([ check_upgrade/1
        , perform_upgrade/1
        , permanent_upgrade/2
        ]).

-type state() :: #{
    upgrade_path => list(string()),
    current_vsn => string()
}.

%%==============================================================================
%% API
%%==============================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

check_upgrade(_TargetVsn) ->
    check_write_permission(),
    ok.

perform_upgrade(TargetVsn) ->
    try 
        RootDir = code:root_dir(),
        {Relup, _OldRel, NewRel, UnpackDir} = setup_files(RootDir, TargetVsn),
        emqx_relup_libs:make_libs_info(NewRel, RootDir)
    of
        LibModInfo ->
            %% Exceptions in eval_relup/3 will not be caught and the VM will be restarted!
            ok = eval_relup(TargetVsn, Relup, LibModInfo),
            {ok, UnpackDir};
    catch
        throw:Reason ->
            {error, Reason};
        Err:Reason:ST ->
            {error, {Err, Reason, ST}}
    end.

%%==============================================================================
%% gen_server callbacks
%%==============================================================================
-spec init(list()) -> {ok, state()}.
init([]) ->
    {ok, undefined}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%==============================================================================
%% Check Upgrade
%%==============================================================================
check_write_permission() ->
    RootDir = code:root_dir(),
    SubDirs = ["lib", "releases", "bin"],
    lists:foreach(fun(SubDir) ->
        do_check_write_permission(RootDir, SubDir)
    end, SubDirs).

do_check_write_permission(RootDir, SubDir) ->
    File = filename:join([RootDir, SubDir, "relup_test_perm"]),
    case file:write_file(File, "t") of
        {error, eacces} ->
            throw({no_write_permission, #{dir => SubDir,
                msg => "Please set emqx as the owner of the dir by running:"
                       " 'sudo chown -R emqx:emqx " ++ SubDir ++ "'"}});
        {error, Reason} ->
            throw({cannot_write_file, #{dir => SubDir, reason => Reason}});
        ok ->
            ok = file:delete(File)
    end.

%%==============================================================================
%% Setup Upgrade
%%==============================================================================
setup_files(RootDir, TargetVsn) ->
    {ok, UnpackDir} = unpack_release(TargetVsn),
    {ok, OldRel} = consult_rel_file(RootDir, emqx_release:version()),
    {ok, NewRel} = consult_rel_file(UnpackDir, TargetVsn),
    ok = copy_libs(TargetVsn, RootDir, UnpackDir, OldRel, NewRel),
    ok = copy_release(TargetVsn, RootDir, UnpackDir),
    {load_relup_file(TargetVsn, RootDir), OldRel, NewRel, UnpackDir}.

unpack_release(TargetVsn) ->
    TarFile = filename:join([code:priv_dir(emqx_relup), relups, TargetVsn ++ ".tar.gz"]),
    UnpackDir = filename:join(["tmp", TargetVsn]),
    ok = file:del_dir(UnpackDir),
    ok = file_lib:ensure_dir(filename:join([TargetVsn, "dummy"])),
    ok = erl_tar:extract(TarFile, [{cwd, UnpackDir}, compressed]),
    {ok, UnpackDir}.

copy_libs(_TargetVsn, RootDir, UnpackDir, OldRel, NewRel) ->
    OldLibs = emqx_relup_libs:rel_libs(OldRel),
    NewLibs = emqx_relup_libs:rel_libs(NewRel),
    do_copy_libs(OldLibs, NewLibs, RootDir, UnpackDir).

do_copy_libs([OLib | Libs], NewLibs, RootDir, UnpackDir) ->
    case lists:keyfind(emqx_relup_libs:lib_app_name(OLib), 1, NewLibs) of
        false ->
            ok = copy_lib(OLib, RootDir, UnpackDir);
        NLib ->
            case emqx_relup_libs:lib_app_vsn(NLib) =:= emqx_relup_libs:lib_app_vsn(OLib) of
                true -> ok;
                false ->
                    ok = copy_lib(OLib, RootDir, UnpackDir)
            end
    end,
    do_copy_libs(Libs, NewLibs, RootDir, UnpackDir);
do_copy_libs([], _, _, _) ->
    ok.

copy_lib(OLib, RootDir, UnpackDir) ->
    LibDirName = emqx_relup_libs:lib_app_name(OLib) ++ "-" ++ lib_app_vsn(OLib),
    DstDir = filename:join([RootDir, "lib", LibDirName]),
    SrcDir = filename:join([UnpackDir, "lib", LibDirName]),
    emqx_relup_filelib:cp_r(SrcDir, DstDir).

load_relup_file(TargetVsn, RootDir) ->
    CurrVsn = emqx_release:version(),
    RelupFile = filename:join([RootDir, "releases", TargetVsn, "relup"]),
    case file:consult(RelupFile) of
        {ok, [RelupL]} ->
            case lists:search(fun(#{target_version := TargetVsn0, from_version := FromVsn}) ->
                        FromVsn =:= CurrVsn andalso TargetVsn0 =:= TargetVsn
                    end, RelupL) of
                false ->
                    throw({no_relup_entry, #{file => RelupFile, from_vsn => CurrVsn, target_vsn => TargetVsn}});
                {value, Relup} ->
                    Relup
            end;
        {ok, RelupL} ->
            throw({invalid_relup_file, #{file => RelupFile, content => RelupL}});
        {error, Reason} ->
            throw({failed_to_read_relup_file, #{file => RelupFile, reason => Reason}})
    end.

copy_release(TargetVsn, RootDir, UnpackDir) ->
    SrcDir = filename:join([UnpackDir, "releases", TargetVsn]),
    DstDir = filename:join([RootDir, "releases", TargetVsn]),
    emqx_relup_filelib:cp_r(SrcDir, DstDir).

%%==============================================================================
%% Permanent Release
%%==============================================================================
permanent_upgrade(TargetVsn, UnpackDir) ->
    overwrite_files(TargetVsn, code:root_dir(), UnpackDir).

overwrite_files(_TargetVsn, RootDir, UnpackDir) ->
    %% The RELEASES file is not required by OTP to start a release but it is
    %% used by bin/nodetool. We also won't write release info to it as we don't
    %% use release_handler anymore.
    TmpDir = filename:join(["tmp", emqx_relup_utils:ts_filename("_relup_bk")]),
    ReleaseFiles0 = ["emqx_vars", "start_erl.data", "RELEASES"],
    ReleaseFiles = [{"releases", File} || File <- ReleaseFiles0],
    Bins0 = ["emqx", "emqx_ctl", "node_dump", "emqx.cmd", "emqx_ctl.cmd",
            "nodetool", "emqx_cluster_rescue"],
    Bins = [{"bin", File} || File <- Bins0],
    case filelib:ensure_dir(filename:join([TmpDir, "dummy"])) of
        ok ->
            try do_overwrite_files(ReleaseFiles ++ Bins, RootDir, UnpackDir, TmpDir)
            catch
                throw:{copy_failed, #{history := History} = Details} ->
                    ok = recover_overwritten_files(History),
                    {error, {copy_failed, maps:remove(history, Details)}}
            end;
        {error, _} = Err ->
            Err
    end.

do_overwrite_files(Files, RootDir, UnpackDir, TmpDir) ->
    lists:foldl(fun({SubDir, File}, Copied) ->
            NewFile = filename:join([UnpackDir, SubDir, File]),
            OldFile = filename:join([RootDir, SubDir, File]),
            TmpFile = filename:join([TmpDir, File]),
            copy_file(OldFile, TmpFile, Copied),
            copy_file(NewFile, OldFile, Copied),
            [{TmpFile, OldFile} | Copied]
        end, [], Files),
    ok.

recover_overwritten_files(History) ->
    lists:foreach(fun({TmpFile, OldFile}) ->
        {ok, _} = file:copy(TmpFile, OldFile)
    end, History).

copy_file(SrcFile, DstFile, Copied) ->
    case file:copy(SrcFile, DstFile) of
        {ok, _} -> ok;
        {error, Reason} ->
            throw({copy_failed, #{reason => Reason, src => SrcFile, dst => DstFile, history => Copied}})
    end.

%%==============================================================================
%% Eval Relup Instructions
%%==============================================================================
eval_relup(TargetVsn, Relup, LibModInfo) ->
    OldVsn = emqx_release:version(),
    ok = eval_code_changes(Relup, LibModInfo),
    eval_post_upgrade_actions(TargetVsn, OldVsn, Relup).

eval_code_changes(Relup, LibModInfo) ->
    CodeChanges = maps:get(code_changes, Relup),
    Instrs = prepare_code_change(CodeChanges, LibModInfo, []),
    ok = write_troubleshoot_file("relup", Instrs),
    eval(Instrs).

prepare_code_change([{load_module, Mod} | CodeChanges], LibModInfo, Instrs) ->
    {Bin, FName} = load_object_code(Mod, LibModInfo),
    _ = erlang:soft_purge(Mod),
    prepare_code_change(CodeChanges, LibModInfo, [{load, Mod, Bin, FName} | Instrs]);
prepare_code_change([{restart_application, AppName} | CodeChanges], LibModInfo, Instrs) ->
    Mods = emqx_relup_libs:get_app_mods(AppName, LibModInfo),
    CodeChanges1 = [{load_module, Mod} || Mod <- Mods] ++ CodeChanges,
    ExpandedInstrs = [{stop_app, AppName}, {remove_app, AppName} | CodeChanges1] ++ [{start_app, AppName}],
    prepare_code_change(ExpandedInstrs, LibModInfo, Instrs);
prepare_code_change([{AppOp, _} = Instr | CodeChanges], LibModInfo, Instrs)
        when AppOp =:= start_app; AppOp =:= stop_app ->
    prepare_code_change(CodeChanges, LibModInfo, [Instr | Instrs]);
prepare_code_change([], _, Instrs) ->
    lists:reverse(Instrs).

load_object_code(Mod, #{mod_app_mapping := ModAppMapping}) ->
    case maps:get(Mod, ModAppMapping) of
        {_AppName, _AppVsn, File} ->
            case erl_prim_loader:get_file(File) of
                {ok, Bin, FName2} ->
                    {Bin, FName2};
                error ->
                    throw({no_such_file, File})
            end;
        undefined -> throw({module_not_found, Mod})
    end.

eval([]) ->
    ok;
eval([{load, Mod, Bin, FName} | Instrs]) ->
    % load_binary kills all procs running old code
    {module, _} = code:load_binary(Mod, FName, Bin),
    eval(Instrs);
eval([{stop_app, AppName} | Instrs]) ->
    case application:stop(AppName) of
        ok -> ok;
        {error, {not_started, _}} -> ok;
        {error, Reason} ->
            throw({failed_to_stop_app, #{app => AppName, reason => Reason}})
    end,
    eval(Instrs);
eval([{remove_app, AppName} | Instrs]) ->
    case application:get_key(AppName, modules) of
        undefined -> ok;
        {ok, Mods} ->
            lists:foreach(fun(M) ->
                    _ = code:purge(M),
                    true = code:delete(M)
                end, Mods)
    end,
    eval(Instrs);
eval([{start_app, AppName} | Instrs]) ->
    {ok, _} = application:ensure_all_started(AppName),
    eval(Instrs).

%%==============================================================================
%% Eval Post Upgrade Actions
%%==============================================================================
eval_post_upgrade_actions(TargetVsn, OldVsn, Relup) ->
    case copy_upgrade_mod(TargetVsn) of
        {ok, Mod} ->
            try
                PostUpgradeActions = maps:get(post_upgrade_callbacks, Relup),
                lists:foldl(fun({Func, RevertFunc}, Rollbacks) ->
                    _ = apply_func(Mod, Func, [OldVsn], Rollbacks),
                    [RevertFunc | Rollbacks]
                end, [], PostUpgradeActions)
            catch
                throw:{apply_func, #{rollbacks := Rollbacks} = Details} ->
                    lists:foreach(fun(RevertFunc) ->
                        apply_func(Mod, RevertFunc, [OldVsn], log)
                    end, Rollbacks),
                    {error, {eval_post_upgrade_actions, maps:remove(rollbacks, Details)}};
                Err:Reason:ST ->
                    {error, {eval_post_upgrade_actions, {Err, Reason, ST}}}
            end;
        {error, Reason} ->
            {error, {copy_upgrade_mod, Reason}}
    end.

apply_func(Mod, Func, Args, Rollbacks) ->
    try erlang:apply(Mod, Func, Args)
    catch
        Err:Reason:ST ->
            case Rollbacks of
                log ->
                    logger:error("Failed to apply function ~p:~p with args ~p, st: ~p",
                        [Mod, Func, Args, {Err, Reason, ST}]);
                _ ->
                    throw({apply_func, #{func => Func, args => Args,
                            reason => {Err, Reason, ST},
                            rollbacks => Rollbacks}})
            end
    end.

copy_upgrade_mod(TargetVsn) ->
    %% copy module from 'emqx_post_upgrade' to 'emqx_post_upgrade_<target_vsn>',
    %% so we can call revert functions in 'emqx_post_upgrade_<target_vsn>' for 
    %% a hot patch version before upgrading to a official version. 
    Mod = list_to_atom("emqx_post_upgrade_" ++ TargetVsn),
    case {code:is_loaded(Mod), code:is_loaded(emqx_post_upgrade)} of
        {{file, loaded}, _} ->
            {ok, Mod};
        {false, false} ->
            {error, {module_not_loaded, emqx_post_upgrade}};
        {false, {file, loaded}} ->
            {Mod, Bin, FName} = code:get_object_code(emqx_post_upgrade),
            case code:load_binary(Mod, Bin, FName) of
                {module, _} -> {ok, Mod};
                {error, Reason} -> {error, Reason}
            end
    end.

%%==============================================================================
%% Internal functions
%%==============================================================================
consult_rel_file(RootDir, TargetVsn) ->
    RelFile = filename:join([RootDir, "releases", TargetVsn, "emqx.rel"]),
    case file:consult(RelFile) of
        {ok, [Release]} ->
            {ok, Release};
        {error, Reason} ->
            throw({failed_to_read_rel_file, #{file => RelFile, reason => Reason}})
    end.

write_troubleshoot_file(Name, Term) ->
    FName = emqx_relup_utils:ts_filename(Name),
    file:write_file(FName, io_lib:format("~p", [Term])).
