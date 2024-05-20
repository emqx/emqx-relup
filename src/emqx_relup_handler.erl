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
        , perform_upgrade/2
        , permanent_upgrade/2
        ]).

-import(lists, [concat/1]).
-import(emqx_relup_utils, [str/1]).

-type state() :: #{
    upgrade_path => list(string()),
    current_vsn => string()
}.

%%==============================================================================
%% API
%%==============================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

check_upgrade(TargetVsn) ->
    try
        RootDir = code:root_dir(),
        {ok, UnpackDir} = unpack_release(TargetVsn),
        ok = check_write_permission(),
        ok = check_otp_comaptibility(RootDir, UnpackDir, TargetVsn),
        {ok, UnpackDir}
    catch
        throw:Reason ->
            {error, Reason};
        Err:Reason:ST ->
            {error, {Err, Reason, ST}}
    end.

perform_upgrade(TargetVsn, UnpackDir) ->
    try 
        RootDir = code:root_dir(),
        {Relup, _OldRel, NewRel} = setup_files(RootDir, UnpackDir, TargetVsn),
        emqx_relup_libs:make_libs_info(NewRel, RootDir)
    of
        LibModInfo ->
            eval_relup(TargetVsn, Relup, LibModInfo)
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

check_otp_comaptibility(RootDir, UnpackDir, TargetVsn) ->
    CurrBuildInfo = read_build_info(RootDir, emqx_release:version()),
    NewBuildInfo = read_build_info(UnpackDir, TargetVsn),
    CurrOTPVsn = maps:get("erlang", CurrBuildInfo),
    NewOTPVsn = maps:get("erlang", NewBuildInfo),
    %% 1. We may need to update the OTP version to fix some bugs so here we only check the major version.
    assert_same_major_vsn(CurrOTPVsn, NewOTPVsn),
    %% 2. We have our own OTP fork, so here we make sure the new OTP version is also from our fork,
    %%    otherwise the emqx may failed to get started due to mira problems.
    assert_same_otp_fork(CurrOTPVsn, NewOTPVsn),
    %% 3. We need to make sure the os arch the same, otherwise the emqx will fail to load NIFs.
    assert_same_os_arch(CurrBuildInfo, NewBuildInfo).

assert_same_major_vsn(CurrOTPVsn, NewOTPVsn) ->
    case emqx_relup_utils:major_vsn(CurrOTPVsn) =:= emqx_relup_utils:major_vsn(NewOTPVsn) of
        true -> ok;
        false -> throw({otp_major_vsn_mismatch, #{curr => CurrOTPVsn, new => NewOTPVsn}})
    end.

assert_same_otp_fork(CurrOTPVsn, NewOTPVsn) ->
    CurrFork = emqx_relup_utils:fork_type(CurrOTPVsn),
    NewFork = emqx_relup_utils:fork_type(NewOTPVsn),
    case CurrFork =:= NewFork of
        true -> ok;
        false -> throw({otp_fork_type_mismatch, #{curr => CurrOTPVsn, new => NewOTPVsn}})
    end.

assert_same_os_arch(CurrBuildInfo, NewBuildInfo) ->
    case maps:get("os", CurrBuildInfo) =:= maps:get("os", NewBuildInfo) andalso
         emqx_relup_utils:is_arch_compatible(maps:get("arch", CurrBuildInfo), maps:get("arch", NewBuildInfo)) of
        true -> ok;
        false -> throw({os_arch_mismatch, #{curr => CurrBuildInfo, new => NewBuildInfo}})
    end.

%%==============================================================================
%% Setup Upgrade
%%==============================================================================
setup_files(RootDir, UnpackDir, TargetVsn) ->
    {ok, OldRel} = consult_rel_file(RootDir, emqx_release:version()),
    {ok, NewRel} = consult_rel_file(UnpackDir, TargetVsn),
    ok = copy_libs(TargetVsn, RootDir, UnpackDir, OldRel, NewRel),
    ok = copy_release(TargetVsn, RootDir, UnpackDir),
    {load_relup_file(TargetVsn, RootDir), OldRel, NewRel}.

unpack_release(TargetVsn) ->
    TarFile = filename:join([code:priv_dir(emqx_relup), concat([TargetVsn, ".tar.gz"])]),
    case filelib:is_regular(TarFile) of
        false ->
            throw({relup_tar_file_not_found, TarFile});
        true ->
            TmpDir = emqx_relup_file_utils:tmp_dir(),
            UnpackDir = filename:join([TmpDir, TargetVsn]),
            ok = emqx_relup_file_utils:ensure_dir_deleted(UnpackDir),
            ok = filelib:ensure_dir(filename:join([UnpackDir, "dummy"])),
            ok = erl_tar:extract(TarFile, [{cwd, UnpackDir}, compressed]),
            {ok, UnpackDir}
    end.

copy_libs(_TargetVsn, RootDir, UnpackDir, OldRel, NewRel) ->
    OldLibs = emqx_relup_libs:rel_libs(OldRel),
    NewLibs = emqx_relup_libs:rel_libs(NewRel),
    do_copy_libs(NewLibs, OldLibs, RootDir, UnpackDir).

do_copy_libs([NLib | Libs], OldLibs, RootDir, UnpackDir) ->
    AppName = emqx_relup_libs:lib_app_name(NLib),
    case lists:keyfind(AppName, 1, OldLibs) of
        false -> %% this lib is newly added, copy it
            ok = copy_lib(NLib, RootDir, UnpackDir);
        OLib -> %% this lib is already in the old release, copy it only if the version is changed
            case emqx_relup_libs:lib_app_vsn(OLib) =:= emqx_relup_libs:lib_app_vsn(NLib) of
                true -> ok;
                false ->
                    ok = copy_lib(NLib, RootDir, UnpackDir)
            end
    end,
    do_copy_libs(Libs, OldLibs, RootDir, UnpackDir);
do_copy_libs([], _, _, _) ->
    ok.

copy_lib(NLib, RootDir, UnpackDir) ->
    LibDirName = concat([emqx_relup_libs:lib_app_name(NLib), "-", emqx_relup_libs:lib_app_vsn(NLib)]),
    DstDir = filename:join([RootDir, "lib", LibDirName]),
    SrcDir = filename:join([UnpackDir, "lib", LibDirName]),
    logger:warning("copy lib from ~s to ~s", [SrcDir, DstDir]),
    emqx_relup_file_utils:cp_r(SrcDir, DstDir).

load_relup_file(TargetVsn, RootDir) ->
    CurrVsn = emqx_release:version(),
    RelupFile = filename:join([RootDir, "releases", TargetVsn, concat([TargetVsn, ".relup"])]),
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
    emqx_relup_file_utils:cp_r(SrcDir, DstDir).

%%==============================================================================
%% Permanent Release
%%==============================================================================
permanent_upgrade(TargetVsn, UnpackDir) ->
    overwrite_files(TargetVsn, code:root_dir(), UnpackDir).

overwrite_files(_TargetVsn, RootDir, UnpackDir) ->
    %% The RELEASES file is not required by OTP to start a release but it is
    %% used by bin/nodetool. We also won't write release info to it as we don't
    %% use release_handler anymore.
    TmpDir0 = emqx_relup_file_utils:tmp_dir(),
    TmpDir = filename:join([TmpDir0, emqx_relup_utils:ts_filename("_relup_bk")]),
    ReleaseFiles0 = ["emqx_vars", "start_erl.data", "RELEASES"],
    ReleaseFiles = [{"releases", File} || File <- ReleaseFiles0],
    Bins0 = ["emqx", "emqx_ctl", "node_dump", "emqx.cmd", "emqx_ctl.cmd",
            "nodetool", "emqx_cluster_rescue"],
    Bins = [{"bin", File} || File <- Bins0],
    case filelib:ensure_dir(filename:join([TmpDir, "dummy"])) of
        ok ->
            try
                ok = do_overwrite_files(ReleaseFiles ++ Bins, RootDir, UnpackDir, TmpDir),
                %% We already have emqx.rel files in "releases/<vsn>/emqx.rel",
                %% so we don't need the one in "releases/".
                ExraRel = filename:join([RootDir, "releases", "emqx.rel"]),
                emqx_relup_file_utils:ensure_file_deleted(ExraRel)
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
    %% NOTE: Exceptions in eval_code_changes/2 will not be caught and the VM will be restarted!
    ok = eval_code_changes(Relup, LibModInfo),
    try eval_post_upgrade_actions(TargetVsn, OldVsn, Relup)
    catch
        Err:Reason:ST ->
            {error, {eval_post_upgrade_actions, {Err, Reason, ST}}}
    end.

eval_code_changes(Relup, LibModInfo) ->
    CodeChanges = maps:get(code_changes, Relup),
    ModProcs = release_handler_1:get_supervised_procs(),
    Instrs = prepare_code_change(CodeChanges, LibModInfo, ModProcs, []),
    ok = write_troubleshoot_file("relup", strip_instrs(Instrs)),
    eval(Instrs).

prepare_code_change([{load_module, Mod} | CodeChanges], LibModInfo, ModProcs, Instrs) ->
    {Bin, FName} = load_object_code(Mod, LibModInfo),
    %% TODO: stop the upgrade if some processes are still running the old code
    _ = code:soft_purge(Mod),
    prepare_code_change(CodeChanges, LibModInfo, ModProcs, [{load, Mod, Bin, FName} | Instrs]);
prepare_code_change([{restart_application, AppName} | CodeChanges], LibModInfo, ModProcs, Instrs) ->
    Mods = emqx_relup_libs:get_app_mods(AppName, LibModInfo),
    CodeChanges1 = [{load_module, Mod} || Mod <- Mods] ++ CodeChanges,
    ExpandedInstrs = [{stop_app, AppName}, {remove_app, AppName} | CodeChanges1] ++ [{start_app, AppName}],
    prepare_code_change(ExpandedInstrs, LibModInfo, ModProcs, Instrs);
prepare_code_change([{update, Mod, Change} | CodeChanges], LibModInfo, ModProcs, Instrs) ->
    Pids = pids_of_callback_mod(Mod, ModProcs),
    ExpandedInstrs = [{suspend, Pids}, {load_module, Mod}, {code_change, Pids, Mod, Change},
                      {resume, Pids}] ++ CodeChanges,
    prepare_code_change(ExpandedInstrs, LibModInfo, ModProcs, Instrs);
prepare_code_change([Instr | CodeChanges], LibModInfo, ModProcs, Instrs) ->
    prepare_code_change(CodeChanges, LibModInfo, ModProcs, [assert_valid_instrs(Instr) | Instrs]);
prepare_code_change([], _, _, Instrs) ->
    lists:reverse(Instrs).

pids_of_callback_mod(Mod, ModProcs) ->
    lists:filtermap(fun({_Sup, _Name, Pid, Mods}) ->
            case lists:member(Mod, Mods) of
                true -> {true, Pid};
                false -> false
            end
        end, ModProcs).

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

assert_valid_instrs({load, _, _, _} = Instr) ->
    Instr;
assert_valid_instrs({suspend, Pids} = Instr) when is_list(Pids) ->
    Instr;
assert_valid_instrs({resume, Pids} = Instr) when is_list(Pids) ->
    Instr;
assert_valid_instrs({code_change, Pids, Mod, {advanced, _Extra}} = Instr)
        when is_list(Pids), is_atom(Mod) ->
    Instr;
assert_valid_instrs({stop_app, AppName} = Instr) when is_atom(AppName) ->
    Instr;
assert_valid_instrs({remove_app, AppName} = Instr) when is_atom(AppName) ->
    Instr;
assert_valid_instrs({start_app, AppName} = Instr) when is_atom(AppName) ->
    Instr;
assert_valid_instrs(Instr) ->
    throw({invalid_instr, Instr}).

eval([]) ->
    ok;
eval([{load, Mod, Bin, FName} | Instrs]) ->
    % load_binary kills all procs running old code
    {module, _} = code:load_binary(Mod, FName, Bin),
    eval(Instrs);
eval([{suspend, Pids} | Instrs]) ->
    lists:foreach(fun(Pid) ->
            case catch sys:suspend(Pid) of
                ok -> {true, Pid};
                _ ->
                    % If the proc hangs, make sure to
                    % resume it when it gets suspended!
                    catch sys:resume(Pid)
            end
        end, Pids),
    eval(Instrs);
eval([{resume, Pids} | Instrs]) ->
    lists:foreach(fun(Pid) ->
            catch sys:resume(Pid)
        end, Pids),
    eval(Instrs);
eval([{code_change, Pids, Mod, {advanced, Extra}} | Instrs]) ->
    FromVsn = emqx_release:version(),
    lists:foreach(fun(Pid) ->
            change_code(Pid, Mod, FromVsn, Extra)
        end, Pids),
    eval(Instrs);
eval([{stop_app, AppName} | Instrs]) ->
    case is_excluded_app(AppName) orelse application:stop(AppName) of
        true -> ok;
        ok -> ok;
        {error, {not_started, _}} -> ok;
        {error, Reason} ->
            throw({failed_to_stop_app, #{app => AppName, reason => Reason}})
    end,
    eval(Instrs);
eval([{remove_app, AppName} | Instrs]) ->
    case is_excluded_app(AppName) orelse application:get_key(AppName, modules) of
        true -> ok;
        undefined -> ok;
        {ok, Mods} ->
            lists:foreach(fun(M) ->
                    _ = code:purge(M),
                    true = code:delete(M)
                end, Mods)
    end,
    eval(Instrs);
eval([{start_app, AppName} | Instrs]) ->
    case is_excluded_app(AppName) of
        true -> ok;
        false ->
            {ok, _} = application:ensure_all_started(AppName)
    end,
    eval(Instrs).

change_code(Pid, Mod, FromVsn, Extra) ->
    case sys:change_code(Pid, Mod, FromVsn, Extra) of
        ok -> ok;
        {error, Reason} ->
            throw({code_change_failed, #{
                pid => Pid, mod => Mod, from_vsn => FromVsn,
                extra => Extra, reason => Reason}})
    end.

%%==============================================================================
%% Eval Post Upgrade Actions
%%==============================================================================
eval_post_upgrade_actions(TargetVsn, OldVsn, Relup) ->
    case get_upgrade_mod(TargetVsn) of
        {ok, Mod} ->
            try
                PostUpgradeActions = maps:get(post_upgrade_callbacks, Relup),
                _ = lists:foldl(fun({Func, RevertFunc}, Rollbacks) ->
                    _ = apply_func(Mod, Func, [OldVsn], Rollbacks),
                    [RevertFunc | Rollbacks]
                end, [], PostUpgradeActions),
                ok
            catch
                %% Here we try our best to revert the applied functions, so that
                %% we have a clean system before we try the upgrade again.
                throw:{apply_func, #{rollbacks := Rollbacks} = Details} ->
                    lists:foreach(fun(RevertFunc) ->
                        apply_func(Mod, RevertFunc, [OldVsn], log)
                    end, Rollbacks),
                    {error, {eval_post_upgrade_actions, maps:remove(rollbacks, Details)}};
                Err:Reason:ST ->
                    {error, {eval_post_upgrade_actions, {Err, Reason, ST}}}
            end;
        {error, Reason} ->
            {error, Reason}
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

get_upgrade_mod(TargetVsn) ->
    TaggedMod = list_to_atom(concat(["emqx_post_upgrade_", TargetVsn])),
    Mod = emqx_post_upgrade,
    case {code:is_loaded(TaggedMod), code:is_loaded(Mod)} of
        {{file, _}, _} ->
            {ok, TaggedMod};
        {false, {file, _}} ->
            {ok, Mod};
        {false, false} ->
            {error, {post_upgrade_module_not_loaded, #{mod => Mod}}}
    end.

%%==============================================================================
%% Internal functions
%%==============================================================================
read_build_info(RootDir, Vsn) ->
    BuildInfoFile = filename:join([RootDir, "releases", Vsn, "BUILD_INFO"]),
    Lines = readlines(BuildInfoFile),
    lists:foldl(fun(Line, Map) ->
            case string:split(Line, ":") of
                [Key, Value] ->
                    Map#{str(trim(Key)) => trim(Value)};
                _ -> Map
            end
        end, #{}, Lines).

trim(Str) ->
    string:trim(Str, both, " \"").

readlines(FileName) ->
    {ok, Device} = file:open(FileName, [read]),
    try get_all_lines(Device)
    after file:close(Device)
    end.

get_all_lines(Device) ->
    case file:read_line(Device) of
        eof -> [];
        {ok, Line} -> [Line | get_all_lines(Device)];
        {error, Reason} -> throw({failed_to_read_file, Reason})
    end.

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

%% sticky directories that are not allowed to be upgraded
is_excluded_app(kernel) -> true;
is_excluded_app(stdlib) -> true;
is_excluded_app(compiler) -> true;
is_excluded_app(_) -> false.

strip_instrs([{load, Mod, _Bin, FName} | Instrs]) ->
    %% Bin makes no sense and is too large to be printed
    [{load, Mod, '_', FName} | strip_instrs(Instrs)];
strip_instrs([Instr | Instrs]) ->
    [Instr | strip_instrs(Instrs)];
strip_instrs([]) -> [].
