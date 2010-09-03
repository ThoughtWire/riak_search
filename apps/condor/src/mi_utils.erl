%% -------------------------------------------------------------------
%%
%% mi: Merge-Index Data Store
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc. All Rights Reserved.
%%
%% -------------------------------------------------------------------
-module(mi_utils).
-author("Rusty Klophaus <rusty@basho.com>").
-include("merge_index.hrl").
-export([
         term_compare_fun/2,
         value_compare_fun/2,
         ets_keys/1
]).


%% Used by mi_server.erl to compare two terms, for merging
%% segments. Return true if items are in order.
term_compare_fun({Index1, Field1, Term1, Value1, _, TS1}, {Index2, Field2, Term2, Value2, _, TS2}) ->
    (Index1 < Index2) %% Check for Index ordering. (Ascending)
        orelse 
        ((Index1 == Index2) andalso %% Check for Field ordering. (Ascending)
         (Field1 < Field2)) 
        orelse %% 
        ((Index1 == Index2) andalso %% Check for Term ordering. (Ascending)
         (Field1 == Field2) andalso
         (Term1 < Term2))
        orelse
        ((Index1 == Index2) andalso %% Check for Value ordering. (Ascending)
         (Field1 == Field2) andalso 
         (Term1 == Term2) andalso 
         (Value1 < Value2)) 
        orelse
        ((Index1 == Index2) andalso %% Check for Timestamp ordering. (Descending)
         (Field1 == Field2) andalso 
         (Term1 == Term2) andalso 
         (Value1 == Value2) andalso 
         (TS1 > TS2)).

%% Used by mi_server.erl to compare two values, for streaming ordered
%% results back to a caller. Return true if items are in order.
value_compare_fun({Value1, _, TS1}, {Value2, _, TS2}) ->
    (Value1 < Value2) %% Check for value ordering. (Ascending)
        orelse
          ((Value1 == Value2) andalso  %% Check for timestamp ordering (Descending)
           (TS1 > TS2)).

ets_keys(Table) ->
    Key = ets:first(Table),
    ets_keys_1(Table, Key).
ets_keys_1(_Table, '$end_of_table') ->
    [];
ets_keys_1(Table, Key) ->
    [Key|ets_keys_1(Table, ets:next(Table, Key))].