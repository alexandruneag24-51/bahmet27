%%%-------------------------------------------------------------------
%%% @doc bahmet_app — punctul de intrare al aplicației OTP.
%%% Un `circle` din DSL compilează exact în asta.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    bahmet_sup:start_link().

stop(_State) ->
    ok.
