-module(emqx_relup_libs).

-export([ make_libs_info/2
        , get_app_mods/2
        , rel_libs/1
        , rel_vsn/1
        , rel_erts_vsn/1
        , lib_app_name/1
        , lib_app_vsn/1
        ]).


make_libs_info(Rel, RootDir) ->
    AppDescList = make_app_desc_list(rel_libs(Rel), RootDir),
    #{
        mod_app_mapping => make_mod_app_mapping(AppDescList, RootDir),
        app_desc_list => AppDescList
    }.

get_app_mods(AppName, #{app_desc_list := AppDescL}) ->
    case lists:keyfind(AppName, 2, AppDescL) of
        false -> throw({app_not_found, AppName});
        {application, AppName, Attrs} ->
            emqx_relup_utils:assert_propl_get(modules, Attrs,
                no_modules_in_app_desc, #{func => get_app_mods, app => AppName})
    end.

rel_libs({release, _Emqx, _Erts, Libs}) ->
    Libs.
rel_vsn({release, {"emqx", Vsn}, _Erts, _Libs}) ->
    Vsn.
rel_erts_vsn({release, _Emqx, {erts, Vsn}, _Libs}) ->
    Vsn.

lib_app_name(Lib) ->
    element(1, Lib).
lib_app_vsn(Lib) ->
    element(2, Lib).

%%==============================================================================
%% Internal functions
%%==============================================================================
make_app_desc_list(Libs, RootDir) ->
    lists:map(fun({AppName, AppVsn}) ->
        AppDescFile = filename:join([RootDir, "lib", AppName ++ "-" ++ AppVsn, "ebin", AppName ++ ".app"]),
        case file:consult(AppDescFile) of
            {ok, [AppDesc]} -> AppDesc;
            {error, Reason} ->
                throw({failed_to_read_app_desc_file, #{file => AppDescFile, reason => Reason}})
        end
    end, Libs).

make_mod_app_mapping(AppDescList, RootDir) ->
    lists:foldl(fun({application, AppName, Attrs}, Map) ->
        Mods = emqx_relup_utils:assert_propl_get(modules, Attrs, no_modules_in_app_desc, #{app => AppName}),
        AppVsn = emqx_relup_utils:assert_propl_get(vsn, Attrs, no_vsn_in_app_desc, #{app => AppName}),
        BeamFile = fun(Mod) ->
            filename:join([RootDir, "lib", AppName ++ "-" ++ AppVsn, "ebin", Mod ++ ".beam"])
        end,
        ModMaps = maps:from_list([{M, {AppName, AppVsn, BeamFile(M)}} || M <- Mods]),
        maps:merge(Map, ModMaps)
    end, #{}, AppDescList).
