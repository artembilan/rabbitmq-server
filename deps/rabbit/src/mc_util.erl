-module(mc_util).

-export([is_valid_shortstr/1,
         is_utf8_no_null/1,
         uuid_to_string/1]).

-spec is_valid_shortstr(term()) -> boolean().
is_valid_shortstr(Bin) when byte_size(Bin) < 256 ->
    is_utf8_no_null(Bin);
is_valid_shortstr(_) ->
    false.

is_utf8_no_null(<<>>) ->
    true;
is_utf8_no_null(<<0, _/binary>>) ->
    false;
is_utf8_no_null(<<_/utf8, Rem/binary>>) ->
    is_utf8_no_null(Rem);
is_utf8_no_null(_) ->
    false.

-spec uuid_to_string(binary()) -> binary().
uuid_to_string(<<TL:32, TM:16, THV:16, CSR:8, CSL:8, N:48>>) ->
    list_to_binary(
      io_lib:format(<<"run:uuid:~8.16.0b-~4.16.0b-~4.16.0b-~2.16.0b~2.16.0b-~12.16.0b">>,
                    [TL, TM, THV, CSR, CSL, N])).