-module(emqx_relup_cli).

%% This is an example on how to extend `emqx ctl` with your own commands.

-export([cmd/1]).

cmd(["upgrade", TargetVsn]) ->
    emqx_relup:upgrade(TargetVsn),
    emqx_ctl:print("ok");

cmd(_) ->
    emqx_ctl:usage([{"upgrade <TargetVsn>", "upgrade 5.7.1"}]).
