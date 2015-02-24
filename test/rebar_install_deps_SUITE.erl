-module(rebar_install_deps_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> [{group, git}, {group, pkg}].

groups() ->
    [{all, [], [flat, pick_highest_left, pick_highest_right,
                pick_smallest1, pick_smallest2,
                circular1, circular2, circular_skip]},
     {git, [], [{group, all}]},
     {pkg, [], [{group, all}]}].

init_per_suite(Config) ->
    application:start(meck),
    Config.

end_per_suite(_Config) ->
    application:stop(meck).

init_per_group(git, Config) ->
    [{deps_type, git} | Config];
init_per_group(pkg, Config) ->
    [{deps_type, pkg} | Config];
init_per_group(_, Config) ->
    Config.

end_per_group(_, Config) ->
    Config.

init_per_testcase(Case, Config) ->
    {Deps, Warnings, Expect} = deps(Case),
    Expected = case Expect of
        {ok, List} -> {ok, format_expected_deps(List)};
        {error, Reason} -> {error, Reason}
    end,
    DepsType = ?config(deps_type, Config),
    mock_warnings(),
    [{expect, Expected},
     {warnings, Warnings}
    | setup_project(Case, Config, rebar_test_utils:expand_deps(DepsType, Deps))].

end_per_testcase(_, Config) ->
    meck:unload(),
    Config.

format_expected_deps(Deps) ->
    [case Dep of
        {N,V} -> {dep, N, V};
        N -> {dep, N}
     end || Dep <- Deps].

%% format:
%% {Spec,
%%  [Warning],
%%  {ok, Result} | {error, Reason}}
%%
%% Spec is a list of levelled dependencies of two possible forms:
%% - {"Name", Spec}
%% - {"Name", "Vsn", Spec}
%%
%% Warnings are going to match on mocked ?WARN(...)
%% calls to be evaluated. An empty list means we do not care about
%% warnings, not that no warnings will be printed. This means
%% the list of warning isn't interpreted to be exhaustive, and more
%% warnings may be generated than are listed.
deps(flat) ->
    {[{"B", []},
      {"C", []}],
     [],
     {ok, ["B", "C"]}};
deps(pick_highest_left) ->
    {[{"B", [{"C", "2", []}]},
      {"C", "1", []}],
     [{"C","2"}],
     {ok, ["B", {"C", "1"}]}};
deps(pick_highest_right) ->
    {[{"B", "1", []},
      {"C", [{"B", "2", []}]}],
     [{"B","2"}],
     {ok, [{"B","1"}, "C"]}};
deps(pick_smallest1) ->
    {[{"B", [{"D", "1", []}]},
      {"C", [{"D", "2", []}]}],
     [{"D","2"}],
     %% we pick D1 because B < C
     {ok, ["B","C",{"D","1"}]}};
deps(pick_smallest2) ->
    {[{"C", [{"D", "2", []}]},
      {"B", [{"D", "1", []}]}],
     [{"D","2"}],
     %% we pick D1 because B < C
     {ok, ["B","C",{"D","1"}]}};
deps(circular1) ->
    {[{"B", [{"A", []}]}, % A is the top-level app
      {"C", []}],
     [],
     {error, {rebar_prv_install_deps, {cycles, [[<<"A">>,<<"B">>]]}}}};
deps(circular2) ->
    {[{"B", [{"C", [{"B", []}]}]},
      {"C", []}],
     [],
     {error, {rebar_prv_install_deps, {cycles, [[<<"B">>,<<"C">>]]}}}};
deps(circular_skip) ->
    %% Never spot the circular dep due to being to low in the deps tree
    %% in source deps
    {[{"B", [{"C", "2", [{"B", []}]}]},
      {"C", "1", [{"D",[]}]}],
     [{"C","2"}],
     {ok, ["B", {"C","1"}, "D"]}}.

setup_project(Case, Config0, Deps) ->
    DepsType = ?config(deps_type, Config0),
    Config = rebar_test_utils:init_rebar_state(
            Config0,
            atom_to_list(Case)++"_"++atom_to_list(DepsType)++"_"
    ),
    AppDir = ?config(apps, Config),
    rebar_test_utils:create_app(AppDir, "A", "0.0.0", [kernel, stdlib]),
    TopDeps = rebar_test_utils:top_level_deps(Deps),
    RebarConf = rebar_test_utils:create_config(AppDir, [{deps, TopDeps}]),
    case DepsType of
        git ->
            mock_git_resource:mock([{deps, rebar_test_utils:flat_deps(Deps)}]);
        pkg ->
            mock_pkg_resource:mock([{pkgdeps, rebar_test_utils:flat_pkgdeps(Deps)}])
    end,
    [{rebarconfig, RebarConf} | Config].

mock_warnings() ->
    %% just let it do its thing, we check warnings through
    %% the call log.
    meck:new(rebar_log, [no_link, passthrough]).

%%% TESTS %%%
flat(Config) -> run(Config).
pick_highest_left(Config) -> run(Config).
pick_highest_right(Config) -> run(Config).
pick_smallest1(Config) -> run(Config).
pick_smallest2(Config) -> run(Config).
circular1(Config) -> run(Config).
circular2(Config) -> run(Config).
circular_skip(Config) -> run(Config).

run(Config) ->
    {ok, RebarConfig} = file:consult(?config(rebarconfig, Config)),
    rebar_test_utils:run_and_check(
        Config, RebarConfig, ["install_deps"], ?config(expect, Config)
    ),
    check_warnings(warning_calls(), ?config(warnings, Config), ?config(deps_type, Config)).

warning_calls() ->
    History = meck:history(rebar_log),
    [{Str, Args} || {_, {rebar_log, log, [warn, Str, Args]}, _} <- History].

check_warnings(_, [], _) ->
    ok;
check_warnings(Warns, [{Name, Vsn} | Rest], Type) ->
    ct:pal("Checking for warning ~p in ~p", [{Name,Vsn},Warns]),
    ?assert(in_warnings(Type, Warns, Name, Vsn)),
    check_warnings(Warns, Rest, Type).

in_warnings(git, Warns, NameRaw, VsnRaw) ->
    Name = iolist_to_binary(NameRaw),
    1 =< length([1 || {_, [AppName, {git, _, {_, Vsn}}]} <- Warns,
                      AppName =:= Name, Vsn =:= VsnRaw]);
in_warnings(pkg, Warns, NameRaw, VsnRaw) ->
    Name = iolist_to_binary(NameRaw),
    Vsn = iolist_to_binary(VsnRaw),
    1 =< length([1 || {_, [AppName, AppVsn]} <- Warns,
                      AppName =:= Name, AppVsn =:= Vsn]).

