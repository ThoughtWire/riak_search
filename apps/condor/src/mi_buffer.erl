%% -------------------------------------------------------------------
%%
%% mi: Merge-Index Data Store
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc. All Rights Reserved.
%%
%% -------------------------------------------------------------------
-module(mi_buffer).
-author("Rusty Klophaus <rusty@basho.com>").
-include("merge_index.hrl").
-export([
    new/1,
    filename/1,
    close_filehandle/1,
    delete/1,
    filesize/1,
    size/1,
    write/7, write/2,
    info/4,
    iterator/1, iterator/4, iterators/6
]).


-ifdef(TEST).
-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(buffer, {
    filename,
    handle,
    table,
    size
}).

%%% Creates a disk-based append-mode buffer file with support for a
%%% sorted iterator.

%% Open a new buffer. Returns a buffer structure.
new(Filename) ->
    %% Open the existing buffer file...
    filelib:ensure_dir(Filename),
    ReadBuffer = 1024 * 1024,
    {ok, WriteOpts} = application:get_env(merge_index, buffer_write_options),
    {ok, FH} = file:open(Filename, [read, write, raw, binary,
                                    {read_ahead, ReadBuffer}] ++ WriteOpts),

    %% Read into an ets table...
    Table = ets:new(buffer, [duplicate_bag, public]),
    open_inner(FH, Table),
    {ok, Size} = file:position(FH, cur),

    %% Return the buffer.
    #buffer { filename=Filename, handle=FH, table=Table, size=Size }.

open_inner(FH, Table) ->
    case read_value(FH) of
        {ok, {Index, Field, Term, Value, Props, TS}} ->
            write_to_ets(Table, [{Index, Field, Term, Value, Props, TS}]),
            open_inner(FH, Table);
        eof ->
            ok
    end.

filename(Buffer) ->
    Buffer#buffer.filename.

delete(Buffer) ->
    ets:delete(Buffer#buffer.table),
    close_filehandle(Buffer),
    file:delete(Buffer#buffer.filename),
    file:delete(Buffer#buffer.filename ++ ".deleted"),
    ok.

close_filehandle(Buffer) ->
    file:close(Buffer#buffer.handle).

%% Return the current size of the buffer file.
filesize(Buffer) ->
    Buffer#buffer.size.

size(Buffer) ->
    ets:info(Buffer#buffer.table, size).

%% Write the value to the buffer.
%% Returns the new buffer structure.
write(Index, Field, Term, Value, Props, TS, Buffer) ->
    write([{Index, Field, Term, Value, Props, TS}], Buffer).

write(Postings, Buffer) ->
    %% Write to file...
    FH = Buffer#buffer.handle,
    BytesWritten = write_to_file(FH, Postings),

    %% Return a new buffer with a new tree and size...
    write_to_ets(Buffer#buffer.table, Postings),

    %% Return the new buffer.
    Buffer#buffer {
        size = (BytesWritten + Buffer#buffer.size)
    }.

%% Return the number of results under this IFT.
info(Index, Field, Term, Buffer) ->
    Spec = [{{{Index, Field, Term, '_'}, '_', '_'}, [], [true]}],
    ets:select_count(Buffer#buffer.table, Spec).

%% Return an iterator that traverses the entire buffer.
iterator(Buffer) ->
    Table = Buffer#buffer.table,
    List1 = ets:tab2list(Table),
    List2 = [{I,F,T,V,P,K} || {{I,F,T},V,P,K} <- List1],
    List3 = lists:sort(fun mi_utils:term_compare_fun/2, List2),
    fun() -> iterate_list(List3) end.

%% Return an iterator that traverses a range of the buffer.
iterator(Index, Field, Term, Buffer) ->
    Table = Buffer#buffer.table,
    List1 = ets:lookup(Table, {Index, Field, Term}),
    List2 = [{V,P,K} || {_Key,V,P,K} <- List1],
    List3 = lists:sort(fun mi_utils:value_compare_fun/2, List2),
    fun() -> iterate_list(List3) end.

%% Return a list of iterators over a range.
iterators(Index, Field, StartTerm, EndTerm, Size, Buffer) ->
    Table = Buffer#buffer.table,
    Keys = mi_utils:ets_keys(Table),
    Filter = fun(Key) ->
                     Key >= {Index, Field, StartTerm} 
                         andalso 
                         Key =< {Index, Field, EndTerm}
                         andalso
                         (Size == all orelse erlang:size(element(3, Key)) == Size)
        end,
    MatchingKeys = lists:filter(Filter, Keys),
    [iterator(I,F,T, Buffer) || {I,F,T} <- MatchingKeys].

%% Turn a list into an iterator.
iterate_list([]) ->
    eof;
iterate_list([H|T]) ->
    {H, fun() -> iterate_list(T) end}.


%% ===================================================================
%% Internal functions
%% ===================================================================

read_value(FH) ->
    case file:read(FH, 2) of
        {ok, <<Size:16/integer>>} ->
            {ok, B} = file:read(FH, Size),
            {ok, binary_to_term(B)};
        eof ->
            eof
    end.

write_to_file(FH, Terms) when is_list(Terms) ->
    %% Convert all values to binaries, count the bytes.
    F = fun(X, {SizeAcc, IOAcc}) ->
                B1 = term_to_binary(X),
                Size = erlang:size(B1),
                B2 = <<Size:16/integer, B1/binary>>,
                {SizeAcc + Size + 2, [B2|IOAcc]}
        end,
    {Size, ReverseIOList} = lists:foldl(F, {0, []}, Terms),
    ok = file:write(FH, lists:reverse(ReverseIOList)),
    Size.

write_to_ets(Table, Postings) ->
    %% Convert to {Key, Value, Props, Tstamp}
    F = fun({Index, Field, Term, Value, Props, Tstamp}) ->
                {{Index, Field, Term}, Value, Props, Tstamp}
        end,
    Postings1 = [F(X) || X <- Postings],
    ets:insert(Table, Postings1).

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

-ifdef(EQC).

-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).

-define(POW_2(N), trunc(math:pow(2, N))).

-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).

g_ift() ->
    choose(0, ?POW_2(62)).

g_value() ->
    non_empty(binary()).

g_props() ->
    list({oneof([word_pos, offset]), choose(0, ?POW_2(31))}).

g_tstamp() ->
    choose(0, ?POW_2(31)).

g_ift_range(IFTs) ->
    ?SUCHTHAT({Start, End}, {oneof(IFTs), oneof(IFTs)}, End >= Start).

make_buffer([], B) ->
    B;
make_buffer([{Ift, Value, Props, Tstamp} | Rest], B0) ->
    B = mi_buffer:write(Ift, Value, Props, Tstamp, B0),
    make_buffer(Rest, B).

fold_iterator(Itr, Fn, Acc0) ->
    fold_iterator_inner(Itr(), Fn, Acc0).

fold_iterator_inner(eof, _Fn, Acc) ->
    lists:reverse(Acc);
fold_iterator_inner({Term, NextItr}, Fn, Acc0) ->
    Acc = Fn(Term, Acc0),
    fold_iterator_inner(NextItr(), Fn, Acc).


prop_basic_test(Root) ->
    ?FORALL(Entries, list({g_ift(), g_value(), g_props(), g_tstamp()}),
            begin
                %% Delete old files
                [file:delete(X) || X <- filelib:wildcard(filename:dirname(Root) ++ "/*")],

                %% Create a buffer
                Buffer = make_buffer(Entries, mi_buffer:new(Root ++ "_buffer")),

                %% Filter the generated entries such that each {IFT, Value} is only present
                %% once and has the latest timestamp for that key
                F = fun({IFT, Value, Props, Tstamp}, Acc) ->
                            case orddict:find({IFT, Value}, Acc) of
                                {ok, {_, ExistingTstamp}} when Tstamp >= ExistingTstamp ->
                                    orddict:store({IFT, Value}, {Props, Tstamp}, Acc);
                                error ->
                                    orddict:store({IFT, Value}, {Props, Tstamp}, Acc);
                                _ ->
                                    Acc
                            end
                    end,
                ExpectedEntries = [{IFT, Value, Props, Tstamp} ||
                                      {{IFT, Value}, {Props, Tstamp}}
                                          <- lists:foldl(F, [], Entries)],

                %% Build a list of what was stored in the buffer
                ActualEntries = fold_iterator(mi_buffer:iterator(Buffer),
                                              fun(Item, Acc0) -> [Item | Acc0] end, []),
                ?assertEqual(ExpectedEntries, ActualEntries),
                true
            end).

prop_iter_range_test(Root) ->
    ?LET(IFTs, non_empty(list(g_ift())),
         ?FORALL({Entries, Range}, {list({oneof(IFTs), g_value(), g_props(), g_tstamp()}), g_ift_range(IFTs)},
            begin
                %% Delete old files
                [file:delete(X) || X <- filelib:wildcard(filename:dirname(Root) ++ "/*")],

                %% Create a buffer
                Buffer = make_buffer(Entries, mi_buffer:new(Root ++ "_buffer")),

                %% Identify those values in the buffer that are in the generated range
                {Start, End} = Range,
                RangeEntries = fold_iterator(iterator(Start, End, Buffer),
                                             fun(Item, Acc0) -> [Item | Acc0] end, []),

                %% Verify that all IFTs within the actual entries satisfy the constraint
                ?assertEqual([], [IFT || {IFT, _, _, _} <- RangeEntries,
                                         IFT < Start, IFT > End]),

                %% Check that the count for the range matches the length of the returned
                %% range entries list
                ?assertEqual(length(RangeEntries), info(Start, End, Buffer)),
                true
            end)).


prop_basic_test_() ->
    test_spec("/tmp/test/mi_buffer_basic", fun prop_basic_test/1).

prop_iter_range_test_() ->
    test_spec("/tmp/test/mi_buffer_iter", fun prop_iter_range_test/1).

test_spec(Root, PropertyFn) ->
    {timeout, 60, fun() ->
                          application:load(merge_index),
                          os:cmd(?FMT("rm -rf ~s; mkdir -p ~s", [Root, Root])),
                          ?assert(eqc:quickcheck(eqc:numtests(250, ?QC_OUT(PropertyFn(Root ++ "/t1")))))
                  end}.



-endif. %EQC
-endif.