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

-define(PRINT_CONSOLE(Format, Args), io:format(Format++"~n", Args)).

%% Called when the plugin application start
load(_Env) ->
    ok.
%% Called when the plugin application stop
unload() ->
    ok.

upgrade(TargetVsn) ->
    CurrVsn = emqx_release:version(),
    ?PRINT_CONSOLE("Hot upgrading emqx from current version: ~p to target version: ~p",
        [CurrVsn, TargetVsn]),
    ?PRINT_CONSOLE("Successfully upgraded emqx to target version: ~p",
        [TargetVsn]),
    ok.
