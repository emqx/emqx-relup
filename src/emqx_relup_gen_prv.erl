-module(emqx_relup_gen_prv).

-export([init/1, do/1, format_error/1]).
-import(emqx_relup_utils, [make_error/2]).

-define(PROVIDER, relup_gen).
-define(DEPS, [{default, release}]).
-define(CLI_OPTS, [
    {relup_dir, $d, "relup-dir", {string, "./relup"},
        "The directory that contains upgrade path file and the *.relup files."
        " The upgrade path file defaults to 'upgrade_path.list'."},
    {path_file_name, $u, "path-file-name", {string, "upgrade_path.list"},
        "The filename that describes the upgrade path."}
]).
-define(INCLUDE_DIRS(ERTS_VSN), [lists:concat(["erts-", ERTS_VSN]), "bin", "lib", "releases"]).
-define(TAR_FILE(VSN), VSN ++ ".tar.gz").

-ifdef(TEST).
-export([gen_compelte_relup/3]).
-endif.

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},
            {namespace, emqx},
            {module, ?MODULE},
            {bare, true},
            {deps, ?DEPS},
            {example, "./rebar3 emqx relup_gen --relup-dir=./relup"},
            {profiles, ['emqx-enterprise']},
            {opts, ?CLI_OPTS},
            {short_desc, "A rebar plugin that helps to generate relup tarball for emqx."},
            {desc, "A rebar plugin that helps to generate relup tarball for emqx."
                   " The tarball will contain a *.relup file and all the necessary"
                   " files to upgrade the emqx release."}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    try safe_do(State)
    catch
        throw:Reason ->
            {error, {?MODULE, Reason}}
    end.

safe_do(State) ->
    {RawArgs, _} = rebar_state:command_parsed_args(State),
    RelupDir = getopt_relup_dir(RawArgs),
    TargetVsn = get_release_vsn(State),
    ErtsVsn = get_erts_vsn(),
    OtpVsn = get_otp_vsn(),
    TarDir = filename:join([rebar_dir:root_dir(State), "_build", "default",
                "plugins", "emqx_relup", "priv"]),
    TarFile = filename:join([TarDir, ?TAR_FILE(TargetVsn)]),
    PathFile = getopt_upgrade_path_file(RelupDir, RawArgs),
    rebar_log:log(info, "generating relup tarball for: ~p", [TargetVsn]),
    rebar_log:log(debug, "using relup dir: ~p", [RelupDir]),
    rebar_log:log(debug, "using upgrade path_file: ~p", [PathFile]),
    #{target_vsn := TargetVsn, upgrade_path := UpgradePath}
        = get_upgrade_path(PathFile, TargetVsn),
    Relups = load_partial_relup_files(RelupDir),
    ok = make_change_log_file(TargetVsn, UpgradePath, State),
    CompleteRelup = gen_compelte_relup(Relups, TargetVsn, UpgradePath),
    InjectedRelup = [inject_relup(Relup) || Relup <- CompleteRelup],
    ok = save_relup_file(InjectedRelup, TargetVsn, State),
    ok = ensure_tar_files_deleted(TarDir),
    ok = make_relup_tarball(TarFile, ErtsVsn, OtpVsn, State),
    rebar_log:log(info, "relup tarball generated: ~p", [TarFile]),
    {ok, State}.

get_upgrade_path(PathFile, TargetVsn) ->
    case file:script(PathFile) of
        {ok, PathDescList} ->
            PathDescList1 = lists:map(fun parse_path_desc/1, PathDescList),
            Search = fun(#{target_vsn := Vsn}) -> Vsn =:= TargetVsn end,
            case lists:search(Search, PathDescList1) of
                false ->
                    Reason = #{target_vsn => TargetVsn, file => PathFile},
                    throw(make_error(target_vsn_not_found_in_path_file, Reason));
                {value, PathDesc} ->
                    PathDesc
            end;
        {error, Reason} ->
            throw(make_error(get_upgrade_path_error, #{error => Reason, file => PathFile}))
    end.

parse_path_desc(FullPathStr) ->
    case parse_upgrade_path_str(FullPathStr) of
        [] -> throw(make_error(empty_upgrade_path, #{path_str => FullPathStr}));
        [_] -> throw(make_error(invalid_upgrade_path, #{path_str => FullPathStr}));
        [TargetVsn | UpgradePath] ->
            #{target_vsn => TargetVsn, upgrade_path => UpgradePath}
    end.
parse_upgrade_path_str(FullPathStr) ->
    [string:trim(S) || S <- string:split(FullPathStr, "<-", all), S =/= ""].

load_partial_relup_files(RelupDir) ->
    %% read all of the *.relup files in the relup directory
    case filelib:wildcard(filename:join([RelupDir, "*.relup"])) of
        [] ->
            throw(make_error(no_relup_files_found, #{dir => RelupDir}));
        Files ->
            lists:foldl(fun(File, Acc) ->
                case file:script(File) of
                    {ok, #{target_version := TargetVsn, from_version := FromVsn} = Relup} ->
                        ok = validate_relup_file(Relup),
                        Acc#{{TargetVsn, FromVsn} => Relup};
                    {error, Reason} ->
                        throw(make_error(load_partial_relup_files_error,
                                #{error => Reason, file => File}))
                end
            end, #{}, Files)
    end.

make_change_log_file(TargetVsn, UpgradePath, State) ->
    BaseVsn = lists:last(UpgradePath),
    ChangeLogScript = filename:join([rebar_dir:root_dir(State), "scripts", "rel", "format-changelog.sh"]),
    File = filename:join([get_rel_dir(State), "releases", TargetVsn,
            io_lib:format("change_log_~s_to_~s.md", [BaseVsn, TargetVsn])]),
    MakeChangeLogCmd = lists:flatten(io_lib:format("~s -b e~s -v e~s > ~s", [ChangeLogScript, BaseVsn, TargetVsn, File])),
    {ok, []} = emqx_relup_file_utils:sh(MakeChangeLogCmd, [{use_stdout, false}]),
    ok.

save_relup_file(Relup, TargetVsn, State) ->
    Filename = io_lib:format("~s.relup", [TargetVsn]),
    RelupFile = filename:join([get_rel_dir(State), "releases", TargetVsn, Filename]),
    case file:write_file(RelupFile, io_lib:format("~p.", [Relup])) of
        ok -> ok;
        {error, Reason} ->
            throw(make_error(save_relup_file_error, #{error => Reason, file => RelupFile}))
    end.

%% Assume that we have a UpgradePath = 5 <- 3 <- 2 <- 1, then we need to have
%%  following relup files: (2 <- 1).relup, (3 <- 2).relup, (5 <- 3).relup, then we
%%  can generate a complete relup file that includes all direct paths:
%%  5 <- 3, 5 <- 2, 5 <- 1
gen_compelte_relup(Relups, TargetVsn, UpgradePath0) ->
    [FirstFromVsn | UpgradePath] = UpgradePath0,
    TargetRelups0 = case search_relup(TargetVsn, FirstFromVsn, Relups) of
        error -> throw(make_error(relup_not_found, #{from => FirstFromVsn, target => TargetVsn}));
        {ok, Relup} -> [Relup]
    end,
    {_, TargetRelups, _} = lists:foldl(fun(FromVsn, {LastResolvedFromVsn, TargetRelups1, RelupsAcc}) ->
            case search_relup(TargetVsn, FromVsn, RelupsAcc) of
                error ->
                    {ok, Part1} = search_relup(TargetVsn, LastResolvedFromVsn, RelupsAcc),
                    case search_relup(LastResolvedFromVsn, FromVsn, RelupsAcc) of
                        error ->
                            throw(make_error(relup_not_found, #{from => FromVsn, target => LastResolvedFromVsn}));
                        {ok, Part2} ->
                            Relup0 = concat_relup(Part1, Part2),
                            {FromVsn, [Relup0 | TargetRelups1],
                             RelupsAcc#{{TargetVsn, FromVsn} => Relup0}}
                    end;
                {ok, Relup1} ->
                    {FromVsn, [Relup1 | TargetRelups1], RelupsAcc}
            end
        end, {FirstFromVsn, TargetRelups0, Relups}, UpgradePath),
    lists:reverse(TargetRelups).

search_relup(TargetVsn, FromVsn, Relups) ->
    maps:find({TargetVsn, FromVsn}, Relups).

concat_relup(#{target_version := A, from_version := B} = Relup1,
             #{target_version := B, from_version := C} = Relup2) ->
    CodeChanges = maps:get(code_changes, Relup2, []) ++ maps:get(code_changes, Relup1, []),
    Callbacks = maps:get(post_upgrade_callbacks, Relup2, []) ++ maps:get(post_upgrade_callbacks, Relup1, []),
    #{
        target_version => A,
        from_version => C,
        code_changes => normalize_code_changes(CodeChanges),
        post_upgrade_callbacks => Callbacks
    };
concat_relup(#{target_version := A, from_version := B},
             #{target_version := C, from_version := D}) ->
    throw(make_error(cannot_concat_relup, #{relup1 => {A, B}, relup2 => {C, D}})).

make_relup_tarball(TarFile, ErtsVsn, _OtpVsn, State) ->
    RelDir = get_rel_dir(State),
    Files = lists:map(fun(Dir) ->
        FullPathDir = filename:join([RelDir, Dir]),
        {Dir, FullPathDir}
    end, ?INCLUDE_DIRS(ErtsVsn)),
    ok = r3_hex_erl_tar:create(TarFile, Files, [compressed]).

inject_relup(Relup) ->
    %% inject emqx_release and emqx_post_upgrade to the end of the list
    CodeChanges = maps:get(code_changes, Relup, []),
    CodeChanges1 =
        lists:filtermap(fun
            ({load_module, emqx_release}) -> false;
            ({load_module, emqx_post_upgrade}) -> false;
            (_) -> true
        end, CodeChanges)
        ++ [{load_module, emqx_post_upgrade}, {load_module, emqx_release}],
    Relup#{code_changes => CodeChanges1}.

%-------------------------------------------------------------------------------
ensure_tar_files_deleted(TarDir) ->
    Files = filelib:wildcard(filename:join([TarDir, ?TAR_FILE("*")])),
    lists:foreach(fun(File) ->
            rebar_log:log(info, "delete old relup tarball: ~p", [File]),
            emqx_relup_file_utils:ensure_file_deleted(File)
        end, Files).

get_rel_dir(State) ->
    filename:join([rebar_dir:base_dir(State), "rel", "emqx"]).

get_otp_vsn() ->
    VsnFile = filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"]),
    {ok, Version} = file:read_file(VsnFile),
    binary_to_list(Version).

get_erts_vsn() ->
    VsnFile = filename:join([code:root_dir(), "releases", "start_erl.data"]),
    {ok, Content} = file:read_file(VsnFile),
    case string:split(Content, " ") of
        [ErtsVsn, _OtpVsn] -> binary_to_list(string:trim(ErtsVsn));
        _ -> throw(make_error(parse_start_erl_data_failed, #{file => VsnFile}))
    end.

get_release_vsn(State) ->
    RelxOpts = rebar_state:get(State, relx, []),
    case lists:keyfind(release, 1, rebar_state:get(State, relx, [])) of
        false ->
            throw(make_error(relx_opts_not_found, #{relx_opts => RelxOpts}));
        {release, {_Name, RelxVsn}, _} ->
            RelxVsn
    end.

getopt_relup_dir(RawArgs) ->
    case proplists:get_value(relup_dir, RawArgs) of
        undefined -> "relup";
        RelupDir -> RelupDir
    end.

getopt_upgrade_path_file(RelupDir, RawArgs) ->
    case proplists:get_value(path_file_name, RawArgs) of
        undefined -> throw(make_error(missing_cmd_opts, #{opt => path_file_name}));
        PathFile -> filename:join([RelupDir, PathFile])
    end.

%-------------------------------------------------------------------------------
validate_relup_file(_Relup) ->
    ok.

normalize_code_changes(CodeChanges) ->
    %% TODO: sort instructions according to dependent relationship
    inject_code_changes(CodeChanges).

inject_code_changes(CodeChanges0) ->
    CodeChanges1 = lists:filter(fun
        ({load_module, emqx_release}) -> false;
        ({load_module, emqx_post_upgrade}) -> false;
        (_) -> true
    end, CodeChanges0),
    CodeChanges2 = append_to_tail({load_module, emqx_release}, CodeChanges1),
    [{load_module, emqx_post_upgrade} | CodeChanges2].

append_to_tail(Elm, List) ->
    lists:reverse([Elm | lists:reverse(List)]).

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).
