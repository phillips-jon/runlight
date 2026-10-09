defmodule Runlight.JS do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # What the port needs of JavaScript's own behaviour, so that every value the
  # SDK writes, compares, or counts is written, compared, and counted the same
  # way here: numbers as `Number.prototype.toString` prints them,
  # `JSON.stringify` and `JSON.parse` (objects keep JavaScript's key order, see
  # `Runlight.JS.Object`), `Number()` and `String()` of any value, string
  # lengths and cuts in UTF-16 code units, the characters `\s` matches, and
  # `Date`'s calendar arithmetic.
  #
  # A JSON value is `nil`, a boolean, a number (an integer, a float, or one of
  # `:infinity`, `:neg_infinity`, and `:nan`, which JavaScript has and Erlang's
  # floats do not), a binary, a list, or a `Runlight.JS.Object`. `:undefined`
  # stands for JavaScript's undefined: an object leaves out a key that holds
  # it, as `JSON.stringify` does, and an array writes it as null.

  alias Runlight.JS.Object

  @type number_value :: Object.number_value()
  @type value :: Object.value()

  # 2^53: every integer up to it is a double exactly.
  @max_safe 9_007_199_254_740_992

  # How deep arrays and objects may nest.
  @max_depth 100_000

  ## Numbers

  @doc """
  `String(n)`: the shortest digits that read back as `n`, in plain notation
  from 1e-7 up to 1e21 and exponential notation outside it, as
  `Number.prototype.toString` writes them.
  """
  @spec format_number(number_value()) :: String.t()
  def format_number(:nan), do: "NaN"
  def format_number(:infinity), do: "Infinity"
  def format_number(:neg_infinity), do: "-Infinity"

  def format_number(n) when is_integer(n) do
    if abs(n) <= @max_safe, do: Integer.to_string(n), else: format_number(to_float(n))
  end

  def format_number(n) when is_float(n) and n == 0, do: "0"

  def format_number(n) when is_float(n) do
    sign = if n < 0, do: "-", else: ""
    {digits, point} = shortest(abs(n))
    k = byte_size(digits)

    body =
      cond do
        k <= point and point <= 21 ->
          digits <> String.duplicate("0", point - k)

        0 < point and point <= 21 ->
          binary_part(digits, 0, point) <> "." <> binary_part(digits, point, k - point)

        -6 < point and point <= 0 ->
          "0." <> String.duplicate("0", -point) <> digits

        true ->
          head = binary_part(digits, 0, 1)
          tail = if k > 1, do: "." <> binary_part(digits, 1, k - 1), else: ""
          exp = point - 1
          head <> tail <> "e" <> if(exp >= 0, do: "+", else: "") <> Integer.to_string(exp)
      end

    sign <> body
  end

  def format_number(%{__struct__: Decimal} = d), do: format_number(decimal(d))

  @doc false
  # The shortest round-tripping digits of a positive float and ECMAScript's n:
  # the value is 0.d1d2...dk * 10^n.
  def shortest(x) do
    text = :erlang.float_to_binary(x, [:short])

    {mantissa, exp} =
      case :binary.split(text, "e") do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    {int, frac} =
      case :binary.split(mantissa, ".") do
        [i, f] -> {i, f}
        [i] -> {i, ""}
      end

    digits = int <> frac
    point = byte_size(int) + exp
    {digits, point} = strip_leading(digits, point)
    {strip_trailing(digits), point}
  end

  defp strip_leading(<<?0, rest::binary>>, point) when rest != "", do: strip_leading(rest, point - 1)
  defp strip_leading(digits, point), do: {digits, point}

  defp strip_trailing(digits) do
    case String.trim_trailing(digits, "0") do
      "" -> "0"
      d -> d
    end
  end

  @doc "A number as the double JavaScript would hold, or a special value."
  @spec to_float(term()) :: float() | :infinity | :neg_infinity | :nan
  def to_float(n) when is_float(n), do: n
  def to_float(n) when n in [:infinity, :neg_infinity, :nan], do: n

  def to_float(n) when is_integer(n) do
    n * 1.0
  rescue
    ArithmeticError -> if n > 0, do: :infinity, else: :neg_infinity
  end

  @doc "`Number.isFinite`."
  @spec finite?(term()) :: boolean()
  def finite?(n), do: is_integer(n) or is_float(n)

  @doc "`Number.isInteger`."
  @spec integer?(term()) :: boolean()
  def integer?(n) when is_integer(n), do: true
  def integer?(n) when is_float(n), do: n == Float.round(n)
  def integer?(_), do: false

  @doc """
  A number as the port keeps it: a float that is a whole number JavaScript
  holds exactly becomes an integer, so `2.0` and `2` are one value.
  """
  @spec normalize(term()) :: term()
  def normalize(n) when is_float(n) and n == trunc(n) and abs(n) <= @max_safe, do: trunc(n)
  def normalize(n), do: n

  @doc "A Decimal from a database as the number JavaScript would read from its text."
  @spec decimal(struct()) :: number_value()
  def decimal(%{__struct__: Decimal} = d), do: Decimal |> apply(:to_string, [d, :normal]) |> number()

  @doc "`Math.round`: halves round up, towards positive infinity. Not finite stays as it is."
  @spec round(number_value()) :: number_value()
  def round(n) when is_integer(n), do: n

  def round(n) when is_float(n) do
    r = Kernel.floor(n)
    if n - r >= 0.5, do: r + 1, else: r
  end

  def round(n), do: n

  @doc "`Math.floor`."
  @spec floor(number_value()) :: number_value()
  def floor(n) when is_integer(n), do: n
  def floor(n) when is_float(n), do: Kernel.floor(n)
  def floor(n), do: n

  @doc "`Math.ceil`."
  @spec ceil(number_value()) :: number_value()
  def ceil(n) when is_integer(n), do: n
  def ceil(n) when is_float(n), do: Kernel.ceil(n)
  def ceil(n), do: n

  @doc "`a / b` as JavaScript divides: Infinity or NaN for a zero divisor."
  @spec divide(number_value(), number_value()) :: number_value()
  def divide(a, b) when is_number(a) and is_number(b) and b != 0, do: a / b
  def divide(a, b) when is_number(a) and is_number(b) and a == 0 and b == 0, do: :nan
  def divide(a, b) when is_number(a) and is_number(b), do: if(a > 0, do: :infinity, else: :neg_infinity)
  def divide(_a, _b), do: :nan

  @doc "A modulo whose result has the sign of `b`."
  @spec modulo(integer(), integer()) :: integer()
  def modulo(a, b), do: Integer.mod(a, b)

  @doc "`Math.floor(a / b)` for whole numbers, `b > 0`."
  @spec floor_div(integer(), pos_integer()) :: integer()
  def floor_div(a, b), do: Integer.floor_div(a, b)

  @doc """
  `Number(value)`: text read as JavaScript reads it (trimmed, empty as 0,
  `0x`, `0o`, and `0b` prefixes, Infinity, and NaN for anything else), null
  and false as 0, true as 1, undefined and objects as NaN, and an array as the
  number of its text.
  """
  @spec number(term()) :: number_value()
  def number(n) when is_integer(n) or is_float(n), do: n
  def number(n) when n in [:infinity, :neg_infinity, :nan], do: n
  def number(nil), do: 0
  def number(true), do: 1
  def number(false), do: 0
  def number(:undefined), do: :nan
  def number(%{__struct__: Decimal} = d), do: decimal(d)
  def number([]), do: 0
  def number([one]), do: one |> string() |> number()
  def number(list) when is_list(list), do: :nan
  def number(text) when is_binary(text), do: number_text(trim(text))
  def number(_), do: :nan

  defp number_text(""), do: 0
  defp number_text("Infinity"), do: :infinity
  defp number_text("+Infinity"), do: :infinity
  defp number_text("-Infinity"), do: :neg_infinity

  defp number_text(<<?0, x, rest::binary>>) when x in [?x, ?X], do: radix(rest, 16)
  defp number_text(<<?0, o, rest::binary>>) when o in [?o, ?O], do: radix(rest, 8)
  defp number_text(<<?0, b, rest::binary>>) when b in [?b, ?B], do: radix(rest, 2)

  defp number_text(text) do
    if Regex.match?(~r/\A[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\z/, text) do
      parse_decimal(text)
    else
      :nan
    end
  end

  defp radix("", _base), do: :nan

  defp radix(digits, base) do
    case Integer.parse(digits, base) do
      {n, ""} -> if n > @max_safe, do: to_float(n), else: n
      _ -> :nan
    end
  end

  defp parse_decimal(text) do
    {sign, body} =
      case text do
        <<?-, r::binary>> -> {"-", r}
        <<?+, r::binary>> -> {"", r}
        r -> {"", r}
      end

    {mantissa, exp} =
      case String.split(body, ["e", "E"]) do
        [m, e] -> {m, e}
        [m] -> {m, "0"}
      end

    {int, frac} =
      case String.split(mantissa, ".") do
        [i, f] -> {i, f}
        [i] -> {i, ""}
      end

    int = if int == "", do: "0", else: int

    if frac == "" and exp == "0" and byte_size(int) < 16 do
      n = String.to_integer(int)
      if sign == "-" and n == 0, do: 0, else: String.to_integer(sign <> int)
    else
      case Float.parse(sign <> int <> "." <> if(frac == "", do: "0", else: frac) <> "e" <> exp) do
        {f, ""} ->
          normalize(f)

        _ ->
          cond do
            String.starts_with?(exp, "-") -> 0
            sign == "-" -> :neg_infinity
            true -> :infinity
          end
      end
    end
  rescue
    ArgumentError -> :nan
  end

  @doc """
  `parseInt(text, 10)`: leading space skipped, an optional sign, then as many
  digits as there are; NaN when there are none.
  """
  @spec parse_int(term()) :: number_value()
  def parse_int(value) do
    text = value |> string() |> trim_start()

    case Regex.run(~r/\A([+-]?)(\d+)/, text) do
      [_, sign, digits] ->
        n = String.to_integer(digits)
        n = if sign == "-", do: -n, else: n
        if abs(n) > @max_safe, do: to_float(n), else: n

      nil ->
        :nan
    end
  end

  @doc """
  `String(value)`: numbers as JavaScript prints them, null as "null",
  undefined as "undefined", booleans as words, an array as its items joined
  with commas, and an object as "[object Object]".
  """
  @spec string(term()) :: String.t()
  def string(s) when is_binary(s), do: s
  def string(nil), do: "null"
  def string(:undefined), do: "undefined"
  def string(true), do: "true"
  def string(false), do: "false"
  def string(n) when is_number(n) or n in [:infinity, :neg_infinity, :nan], do: format_number(n)
  def string(%{__struct__: Decimal} = d), do: format_number(d)
  def string(list) when is_list(list), do: Enum.map_join(list, ",", &item_string/1)
  def string(%Object{}), do: "[object Object]"
  def string(atom) when is_atom(atom), do: Atom.to_string(atom)
  def string(%{}), do: "[object Object]"

  defp item_string(v) when v in [nil, :undefined], do: ""
  defp item_string(v), do: string(v)

  @doc "`value ?? fallback`: the fallback for null and undefined."
  @spec nullish(term(), term()) :: term()
  def nullish(v, fallback) when v in [nil, :undefined], do: fallback
  def nullish(v, _fallback), do: v

  @doc "Whether JavaScript reads the value as true in a condition."
  @spec truthy?(term()) :: boolean()
  def truthy?(v) when v in [nil, false, :undefined, "", 0, :nan], do: false
  def truthy?(v) when is_float(v) and v == 0, do: false
  def truthy?(_), do: true

  @doc "`value || fallback`."
  @spec or_else(term(), term()) :: term()
  def or_else(v, fallback), do: if(truthy?(v), do: v, else: fallback)

  @doc "Whether the value is a JSON object (not null, not an array)."
  @spec object?(term()) :: boolean()
  def object?(%Object{}), do: true
  def object?(_), do: false

  @doc "`typeof value === \"object\" && value` for a JSON value: an object or an array."
  @spec objectish?(term()) :: boolean()
  def objectish?(%Object{}), do: true
  def objectish?(v), do: is_list(v)

  @doc "A property of an object as JavaScript reads it: undefined when it is missing or the value is not an object."
  @spec prop(term(), String.t()) :: term()
  def prop(%Object{} = o, key) do
    case Object.fetch(o, key) do
      {:ok, v} -> v
      :error -> :undefined
    end
  end

  def prop(list, key) when is_list(list) do
    case Integer.parse(key) do
      {i, ""} when i >= 0 -> Enum.at(list, i, :undefined)
      _ -> if key == "length", do: length(list), else: :undefined
    end
  end

  def prop(_, _), do: :undefined

  @doc "A JavaScript object of these pairs, in order: `obj(id: 1, name: \"x\")`."
  @spec obj(Enumerable.t()) :: Object.t()
  def obj(pairs), do: Object.new(pairs)

  ## JSON

  @doc """
  `JSON.stringify`: the same bytes for the same value. A number that is not
  finite is `null`, as JavaScript writes it. Atoms other than `nil`, `true`,
  `false`, and `:undefined` are written as their names, and maps as objects in
  their keys' term order.
  """
  @spec stringify(term()) :: String.t()
  def stringify(v), do: v |> write() |> IO.iodata_to_binary()

  @doc "`JSON.stringify(value, null, indent)`, pretty-printed as JavaScript prints it."
  @spec stringify(term(), non_neg_integer()) :: String.t()
  def stringify(v, 0), do: stringify(v)
  def stringify(v, indent), do: v |> pretty(indent, 0) |> IO.iodata_to_binary()

  defp write(nil), do: "null"
  defp write(:undefined), do: "null"
  defp write(true), do: "true"
  defp write(false), do: "false"
  defp write(n) when n in [:infinity, :neg_infinity, :nan], do: "null"
  defp write(n) when is_integer(n) and abs(n) > @max_safe, do: write(to_float(n))
  defp write(n) when is_number(n), do: format_number(n)
  defp write(%{__struct__: Decimal} = d), do: write(decimal(d))
  defp write(s) when is_binary(s), do: quote_iodata(s)
  defp write(a) when is_atom(a), do: quote_iodata(Atom.to_string(a))
  defp write([]), do: "[]"
  defp write(list) when is_list(list), do: [?[, Enum.intersperse(Enum.map(list, &write/1), ?,), ?]]
  defp write(%Object{pairs: pairs}), do: write_pairs(pairs)
  defp write(%{} = map) when not is_struct(map), do: write(Object.new(map))

  defp write_pairs(pairs) do
    case Enum.reject(pairs, fn {_, v} -> v == :undefined end) do
      [] -> "{}"
      kept -> [?{, Enum.intersperse(Enum.map(kept, fn {k, v} -> [quote_iodata(k), ?:, write(v)] end), ?,), ?}]
    end
  end

  defp pretty(list, indent, level) when is_list(list) and list != [] do
    inner = String.duplicate(" ", indent * (level + 1))
    outer = String.duplicate(" ", indent * level)
    items = Enum.map(list, fn v -> [inner, pretty(v, indent, level + 1)] end)
    ["[\n", Enum.intersperse(items, ",\n"), ?\n, outer, ?]]
  end

  defp pretty(%Object{pairs: pairs} = o, indent, level) do
    case Enum.reject(pairs, fn {_, v} -> v == :undefined end) do
      [] ->
        write(o)

      kept ->
        inner = String.duplicate(" ", indent * (level + 1))
        outer = String.duplicate(" ", indent * level)
        items = Enum.map(kept, fn {k, v} -> [inner, quote_iodata(k), ": ", pretty(v, indent, level + 1)] end)
        ["{\n", Enum.intersperse(items, ",\n"), ?\n, outer, ?}]
    end
  end

  defp pretty(%{} = map, indent, level) when not is_struct(map), do: pretty(Object.new(map), indent, level)
  defp pretty(v, _indent, _level), do: write(v)

  @doc "`JSON.stringify` of a string."
  @spec quote(String.t()) :: String.t()
  def quote(s), do: s |> quote_iodata() |> IO.iodata_to_binary()

  defp quote_iodata(s), do: [?", escape(s, s, 0, 0, []), ?"]

  # Copies runs of bytes that need no escape as slices of the original.
  defp escape(<<>>, orig, start, len, acc), do: Enum.reverse([binary_part(orig, start, len) | acc])

  defp escape(<<c, rest::binary>>, orig, start, len, acc) when c >= 0x20 and c != ?" and c != ?\\ do
    escape(rest, orig, start, len + 1, acc)
  end

  defp escape(<<c, rest::binary>>, orig, start, len, acc) do
    e =
      case c do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        0x08 -> "\\b"
        0x0C -> "\\f"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        _ -> "\\u00" <> hex2(c)
      end

    escape(rest, orig, start + len + 1, 0, [e, binary_part(orig, start, len) | acc])
  end

  defp hex2(c), do: c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

  @doc """
  `JSON.parse`: objects in JavaScript's key order (a key given twice keeps
  its first place and its last value). A lone surrogate escape (`\\ud800`)
  becomes U+FFFD. Text that is not UTF-8 is read with U+FFFD in its place, as
  a TextDecoder reads it.
  """
  @spec parse(String.t()) :: {:ok, value()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    text = scrub(text)
    rest = skip_space(text)

    case value(rest, text, 0) do
      {:ok, v, rest} ->
        case skip_space(rest) do
          "" -> {:ok, v}
          rest -> fail("Unexpected non-whitespace character after JSON", text, rest)
        end

      {:error, _} = e ->
        e
    end
  catch
    {:json_error, message} -> {:error, message}
  end

  @doc "`parse/1`, raising `ArgumentError` on text that is not JSON."
  @spec parse!(String.t()) :: value()
  def parse!(text) do
    case parse(text) do
      {:ok, v} -> v
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "`JSON.parse(text)` or `fallback` when it throws."
  @spec parse_or(String.t() | nil, term()) :: term()
  def parse_or(nil, fallback), do: fallback

  def parse_or(text, fallback) do
    case parse(text) do
      {:ok, v} -> v
      {:error, _} -> fallback
    end
  end

  defp fail(what, text, rest), do: {:error, "#{what} at position #{byte_size(text) - byte_size(rest)}"}

  defp throw_fail(what, text, rest),
    do: throw({:json_error, "#{what} at position #{byte_size(text) - byte_size(rest)}"})

  defp skip_space(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(rest), do: rest

  defp value(_rest, _text, depth) when depth >= @max_depth, do: {:error, "JSON nested too deeply"}
  defp value("", text, _depth), do: fail("Unexpected end of JSON input", text, "")

  defp value(<<?{, rest::binary>>, text, depth) do
    case skip_space(rest) do
      <<?}, rest::binary>> -> {:ok, Object.new(), rest}
      rest -> members(rest, text, depth, {[], %{}})
    end
  end

  defp value(<<?[, rest::binary>>, text, depth) do
    case skip_space(rest) do
      <<?], rest::binary>> -> {:ok, [], rest}
      rest -> elements(rest, text, depth, [])
    end
  end

  defp value(<<?", _::binary>> = rest, text, _depth) do
    {s, rest} = string_literal(rest, text)
    {:ok, s, rest}
  end

  defp value(<<"true", rest::binary>>, _text, _depth), do: {:ok, true, rest}
  defp value(<<"false", rest::binary>>, _text, _depth), do: {:ok, false, rest}
  defp value(<<"null", rest::binary>>, _text, _depth), do: {:ok, nil, rest}
  defp value(<<c, _::binary>> = rest, text, _depth) when c == ?- or c in ?0..?9, do: number_literal(rest, text)
  defp value(rest, text, _depth), do: fail("Unexpected token", text, rest)

  defp members(rest, text, depth, {order, values}) do
    rest = skip_space(rest)

    if match?(<<?", _::binary>>, rest) do
      {k, rest} = string_literal(rest, text)

      case skip_space(rest) do
        <<?:, rest::binary>> ->
          case value(skip_space(rest), text, depth + 1) do
            {:ok, v, rest} ->
              {order, values} =
                if Map.has_key?(values, k),
                  do: {order, %{values | k => v}},
                  else: {[k | order], Map.put(values, k, v)}

              case skip_space(rest) do
                <<?,, rest::binary>> -> members(rest, text, depth, {order, values})
                <<?}, rest::binary>> -> {:ok, Object.from_order(Enum.reverse(order), values), rest}
                rest -> fail("Expected ',' or '}' after property value", text, rest)
              end

            e ->
              e
          end

        rest ->
          fail("Expected ':' after property name", text, rest)
      end
    else
      fail("Expected property name", text, rest)
    end
  end

  defp elements(rest, text, depth, acc) do
    case value(skip_space(rest), text, depth + 1) do
      {:ok, v, rest} ->
        case skip_space(rest) do
          <<?,, rest::binary>> -> elements(rest, text, depth, [v | acc])
          <<?], rest::binary>> -> {:ok, Enum.reverse([v | acc]), rest}
          rest -> fail("Expected ',' or ']' after array element", text, rest)
        end

      e ->
        e
    end
  end

  defp number_literal(rest, text) do
    {sign, r} =
      case rest do
        <<?-, r::binary>> -> {"-", r}
        r -> {"", r}
      end

    {int, r} =
      case r do
        <<?0, r::binary>> ->
          {"0", r}

        r ->
          case digits(r) do
            {"", _} -> throw_fail("No number after minus sign", text, r)
            got -> got
          end
      end

    {frac, r} =
      case r do
        <<?., r2::binary>> ->
          case digits(r2) do
            {"", _} -> throw_fail("Unterminated fractional number", text, r2)
            {d, r3} -> {d, r3}
          end

        r ->
          {nil, r}
      end

    {exp, r} =
      case r do
        <<e, r2::binary>> when e in [?e, ?E] ->
          {esign, r3} =
            case r2 do
              <<s, r3::binary>> when s in [?+, ?-] -> {<<s>>, r3}
              r3 -> {"", r3}
            end

          case digits(r3) do
            {"", _} -> throw_fail("Exponent part is missing a number", text, r3)
            {d, r4} -> {esign <> d, r4}
          end

        r ->
          {nil, r}
      end

    {:ok, to_number(sign, int, frac, exp), r}
  end

  defp digits(rest), do: digits(rest, 0, rest)
  defp digits(<<c, r::binary>>, n, orig) when c in ?0..?9, do: digits(r, n + 1, orig)
  defp digits(r, n, orig), do: {binary_part(orig, 0, n), r}

  defp to_number("-", "0", nil, nil), do: 0
  defp to_number(sign, int, nil, nil) when byte_size(int) < 16, do: String.to_integer(sign <> int)

  defp to_number(sign, int, frac, exp) do
    text = sign <> int <> "." <> (frac || "0") <> "e" <> (exp || "0")

    case Float.parse(text) do
      {f, ""} ->
        normalize(f)

      _ ->
        cond do
          String.starts_with?(exp || "", "-") -> 0
          sign == "-" -> :neg_infinity
          true -> :infinity
        end
    end
  end

  defp string_literal(<<?", rest::binary>>, text), do: chars(rest, text, rest, 0, [])

  defp chars(<<?", rest::binary>>, _text, orig, n, acc) do
    {IO.iodata_to_binary(Enum.reverse([binary_part(orig, 0, n) | acc])), rest}
  end

  defp chars(<<?\\, rest::binary>>, text, orig, n, acc) do
    acc = [binary_part(orig, 0, n) | acc]
    {piece, rest} = escape_seq(rest, text)
    chars(rest, text, rest, 0, [piece | acc])
  end

  defp chars(<<c, _::binary>> = rest, text, _orig, _n, _acc) when c < 0x20 do
    throw_fail("Bad control character in string literal", text, rest)
  end

  defp chars(<<_, rest::binary>>, text, orig, n, acc), do: chars(rest, text, orig, n + 1, acc)
  defp chars(<<>>, text, _orig, _n, _acc), do: throw_fail("Unterminated string", text, "")

  defp escape_seq(<<e, rest::binary>>, _text) when e in [?", ?\\, ?/], do: {<<e>>, rest}
  defp escape_seq(<<?b, rest::binary>>, _text), do: {<<8>>, rest}
  defp escape_seq(<<?f, rest::binary>>, _text), do: {<<12>>, rest}
  defp escape_seq(<<?n, rest::binary>>, _text), do: {"\n", rest}
  defp escape_seq(<<?r, rest::binary>>, _text), do: {"\r", rest}
  defp escape_seq(<<?t, rest::binary>>, _text), do: {"\t", rest}

  defp escape_seq(<<?u, rest::binary>> = at, text) do
    case hex4(rest) do
      {u, rest} when u in 0xD800..0xDBFF ->
        with <<?\\, ?u, r2::binary>> <- rest,
             {lo, r3} when lo in 0xDC00..0xDFFF <- hex4(r2) do
          {<<0x10000 + Bitwise.bsl(u - 0xD800, 10) + (lo - 0xDC00)::utf8>>, r3}
        else
          _ -> {"\u{FFFD}", rest}
        end

      {u, rest} when u in 0xDC00..0xDFFF ->
        {"\u{FFFD}", rest}

      {u, rest} ->
        {<<u::utf8>>, rest}

      nil ->
        throw_fail("Bad Unicode escape", text, binary_part(at, 1, byte_size(at) - 1))
    end
  end

  defp escape_seq(<<>>, text), do: throw_fail("Unterminated string", text, "")
  defp escape_seq(<<_, rest::binary>>, text), do: throw_fail("Bad escaped character", text, rest)

  defp hex4(<<a, b, c, d, rest::binary>>) do
    case Integer.parse(<<a, b, c, d>>, 16) do
      {n, ""} when a not in [?+, ?-] -> {n, rest}
      _ -> nil
    end
  end

  defp hex4(_), do: nil

  ## Text

  @doc "Whether JavaScript's `\\s` matches the code point: WhiteSpace and LineTerminator."
  @spec space?(non_neg_integer()) :: boolean()
  def space?(c) when c in 0x2000..0x200A, do: true

  def space?(c),
    do: c in [?\t, ?\n, 0x0B, 0x0C, ?\r, ?\s, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]

  @doc "`String.prototype.trim`."
  @spec trim(String.t()) :: String.t()
  def trim(s), do: s |> trim_start() |> trim_end()

  @doc "`String.prototype.trimStart`."
  @spec trim_start(String.t()) :: String.t()
  def trim_start(<<c::utf8, rest::binary>> = s), do: if(space?(c), do: trim_start(rest), else: s)
  def trim_start(s), do: s

  @doc "`String.prototype.trimEnd`."
  @spec trim_end(String.t()) :: String.t()
  def trim_end(s) do
    case last_non_space(s, 0, 0) do
      n when n == byte_size(s) -> s
      n -> binary_part(s, 0, n)
    end
  end

  defp last_non_space(<<c::utf8, rest::binary>> = s, at, keep) do
    next = at + (byte_size(s) - byte_size(rest))
    last_non_space(rest, next, if(space?(c), do: keep, else: next))
  end

  defp last_non_space(<<_, rest::binary>>, at, _keep), do: last_non_space(rest, at + 1, at + 1)
  defp last_non_space(<<>>, _at, keep), do: keep

  @doc "`String.prototype.toLowerCase`."
  @spec lower(String.t()) :: String.t()
  def lower(s), do: if(ascii?(s), do: ascii_lower(s), else: String.downcase(s))

  @doc "`String.prototype.toUpperCase`."
  @spec upper(String.t()) :: String.t()
  def upper(s), do: if(ascii?(s), do: ascii_upper(s), else: String.upcase(s))

  defp ascii?(s), do: s == "" or :binary.match(s, Enum.map(128..255, &<<&1>>)) == :nomatch
  defp ascii_lower(s), do: for(<<c <- s>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)
  defp ascii_upper(s), do: for(<<c <- s>>, into: "", do: <<if(c in ?a..?z, do: c - 32, else: c)>>)

  @doc "A string's `.length`: its UTF-16 code units."
  @spec len16(String.t()) :: non_neg_integer()
  def len16(s), do: len16(s, 0)
  defp len16(<<c::utf8, rest::binary>>, n) when c > 0xFFFF, do: len16(rest, n + 2)
  defp len16(<<_::utf8, rest::binary>>, n), do: len16(rest, n + 1)
  defp len16(<<_, rest::binary>>, n), do: len16(rest, n + 1)
  defp len16(<<>>, n), do: n

  @doc """
  `s.slice(start, end)` in UTF-16 code units, with JavaScript's clamping (a
  negative index counts from the end). A cut through a surrogate pair keeps
  the lone half, written here as U+FFFD, the character it becomes once
  written out as UTF-8.
  """
  @spec slice(String.t(), integer(), integer() | nil) :: String.t()
  def slice(s, start, stop \\ nil) do
    if byte_size(s) == 0 do
      ""
    else
      ascii = ascii?(s)
      n = if ascii, do: byte_size(s), else: len16(s)
      stop = if stop == nil, do: n, else: stop
      clamp = fn i -> if i < 0, do: max(i + n, 0), else: min(i, n) end
      {start, stop} = {clamp.(start), clamp.(stop)}

      cond do
        start >= stop -> ""
        start == 0 and stop == n -> s
        ascii -> binary_part(s, start, stop - start)
        true -> s |> cut(0, start, stop, []) |> IO.iodata_to_binary()
      end
    end
  end

  defp cut(<<c::utf8, rest::binary>>, at, start, stop, acc) do
    hi = at + if c > 0xFFFF, do: 2, else: 1

    cond do
      hi <= start -> cut(rest, hi, start, stop, acc)
      at >= stop -> Enum.reverse(acc)
      at >= start and hi <= stop -> cut(rest, hi, start, stop, [<<c::utf8>> | acc])
      true -> cut(rest, hi, start, stop, ["\u{FFFD}" | acc])
    end
  end

  defp cut(<<b, rest::binary>>, at, start, stop, acc) do
    cond do
      at + 1 <= start -> cut(rest, at + 1, start, stop, acc)
      at >= stop -> Enum.reverse(acc)
      true -> cut(rest, at + 1, start, stop, [<<b>> | acc])
    end
  end

  defp cut(<<>>, _at, _start, _stop, acc), do: Enum.reverse(acc)

  @doc "`s.indexOf(sub, from)` in UTF-16 code units, -1 when absent."
  @spec index_of(String.t(), String.t(), non_neg_integer()) :: integer()
  def index_of(s, sub, from \\ 0) do
    rest = if from > 0, do: slice(s, from), else: s

    case :binary.match(rest, sub) do
      {at, _} -> from + len16(binary_part(rest, 0, at))
      :nomatch -> -1
    end
  end

  @doc """
  Text compared as JavaScript's `<` compares it: by UTF-16 code units. -1, 0,
  or 1.
  """
  @spec compare(String.t(), String.t()) :: -1 | 0 | 1
  def compare(a, b) when a == b, do: 0

  def compare(a, b) do
    if ascii?(a) and ascii?(b) do
      if a < b, do: -1, else: 1
    else
      ua = units(a)
      ub = units(b)
      if ua < ub, do: -1, else: 1
    end
  end

  @doc "`a < b` for strings, as JavaScript compares them."
  @spec less?(String.t(), String.t()) :: boolean()
  def less?(a, b), do: compare(a, b) < 0

  @doc "Orders text by code point, as SQLite and Postgres's \"C\" collation do (the store's codeOrder)."
  @spec code_order(String.t(), String.t()) :: integer()
  def code_order(a, b) do
    cond do
      a == b -> 0
      a < b -> -1
      true -> 1
    end
  end

  @doc "The string as UTF-16 code units, big endian, as JavaScript holds it."
  @spec units(String.t()) :: binary()
  def units(s) do
    case :unicode.characters_to_binary(s, :utf8, {:utf16, :big}) do
      bin when is_binary(bin) -> bin
      _ -> s |> scrub() |> :unicode.characters_to_binary(:utf8, {:utf16, :big})
    end
  end

  @doc """
  The text with every byte sequence that is not UTF-8 replaced by U+FFFD, as
  a TextDecoder reads such text.
  """
  @spec scrub(binary()) :: String.t()
  def scrub(s) do
    if String.valid?(s), do: s, else: String.replace_invalid(s, "\u{FFFD}")
  end

  @doc """
  Bytes as a TextDecoder (and `request.text()`) reads them: a leading byte
  order mark dropped, and any byte sequence that is not UTF-8 as U+FFFD.
  """
  @spec decode_utf8(binary()) :: String.t()
  def decode_utf8(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: scrub(rest)
  def decode_utf8(bytes), do: scrub(bytes)

  @doc "`encodeURIComponent`."
  @spec encode_uri_component(String.t()) :: String.t()
  def encode_uri_component(s) do
    for <<b <- s>>, into: "" do
      if b in ?a..?z or b in ?A..?Z or b in ?0..?9 or b in ~c"-_.!~*'()",
        do: <<b>>,
        else: "%" <> String.upcase(Base.encode16(<<b>>))
    end
  end

  @doc "`decodeURIComponent`, or nil where it throws a URIError."
  @spec decode_uri_component(String.t()) :: String.t() | nil
  def decode_uri_component(s) do
    if String.contains?(s, "%") do
      decode_percent(s, [])
    else
      s
    end
  end

  defp decode_percent(<<>>, acc) do
    bin = acc |> Enum.reverse() |> IO.iodata_to_binary()
    if String.valid?(bin) and no_surrogates?(bin), do: bin
  end

  defp decode_percent(<<?%, a, b, rest::binary>>, acc) do
    case Integer.parse(<<a, b>>, 16) do
      {n, ""} when a not in [?+, ?-] -> decode_percent(rest, [<<n>> | acc])
      _ -> nil
    end
  end

  defp decode_percent(<<?%, _::binary>>, _acc), do: nil
  defp decode_percent(<<c, rest::binary>>, acc), do: decode_percent(rest, [<<c>> | acc])

  defp no_surrogates?(bin), do: :unicode.characters_to_list(bin) |> is_list()

  @doc "`btoa` of text whose characters are all bytes (Latin-1), as a binary of those bytes."
  @spec base64(binary()) :: String.t()
  def base64(bytes), do: Base.encode64(bytes)

  @doc "`text.replace(/[&<>\"']/g, ...)`: the HTML escape every page uses."
  @spec escape_html(String.t()) :: String.t()
  def escape_html(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  ## Dates

  @doc "The days since 1970-01-01 of a proleptic Gregorian date, month 1 to 12."
  @spec days_from_civil(integer(), integer(), integer()) :: integer()
  def days_from_civil(y, m, d) do
    y = if m <= 2, do: y - 1, else: y
    era = floor_div(y, 400)
    yoe = y - era * 400
    mp = rem(m + 9, 12)
    doy = div(153 * mp + 2, 5) + d - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    era * 146_097 + doe - 719_468
  end

  @doc "The date of a day counted from 1970-01-01: `{year, month, day}`, month 1 to 12."
  @spec civil_from_days(integer()) :: {integer(), 1..12, 1..31}
  def civil_from_days(z) do
    z = z + 719_468
    era = floor_div(z, 146_097)
    doe = z - era * 146_097
    yoe = div(doe - div(doe, 1460) + div(doe, 36_524) - div(doe, 146_096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = if mp + 3 > 12, do: mp - 9, else: mp + 3
    {if(m <= 2, do: y + 1, else: y), m, d}
  end

  @doc """
  `Date.UTC(year, month, day, hour, minute, second, ms)` with a 0-based
  month, every field free to overflow into the next, as `Date.UTC` allows.
  """
  @spec date_utc(integer(), integer(), integer(), integer(), integer(), integer(), integer()) :: integer()
  def date_utc(year, month, day, hour \\ 0, minute \\ 0, second \\ 0, ms \\ 0) do
    year = year + floor_div(month, 12)
    month = modulo(month, 12)
    days = days_from_civil(year, month + 1, 1) + day - 1
    days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000 + ms
  end

  @doc """
  `new Date(ms).toISOString()`: `"2026-01-05T09:30:00.000Z"`, with a signed
  six-digit year outside 0 to 9999.
  """
  @spec iso_string(integer()) :: String.t()
  def iso_string(ms) do
    days = floor_div(ms, 86_400_000)
    rest = Integer.mod(ms, 86_400_000)
    {y, m, d} = civil_from_days(days)

    year =
      cond do
        y < 0 -> "-" <> pad(-y, 6)
        y > 9999 -> "+" <> pad(y, 6)
        true -> pad(y, 4)
      end

    "#{year}-#{pad(m, 2)}-#{pad(d, 2)}T#{pad(div(rest, 3_600_000), 2)}:#{pad(rem(div(rest, 60_000), 60), 2)}:" <>
      "#{pad(rem(div(rest, 1000), 60), 2)}.#{pad(rem(rest, 1000), 3)}Z"
  end

  @doc "`new Date(ms).toISOString().slice(0, 10)`."
  @spec iso_day(integer()) :: String.t()
  def iso_day(ms), do: ms |> iso_string() |> binary_part(0, 10)

  @doc "`new Date(ms).getUTCDay()`: Sunday is 0."
  @spec utc_weekday(integer()) :: 0..6
  def utc_weekday(ms), do: Integer.mod(floor_div(ms, 86_400_000) + 4, 7)

  @doc false
  def pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  @doc """
  `Date.parse(text)` for the forms the SDK reads: ISO 8601 dates and times
  (a date alone, or with a time and an optional zone, read as UTC when a
  date has no time and as local time, which is UTC on a server running in
  UTC, when a time has no zone), and the RFC 2822 form `Date.toUTCString`
  writes. NaN for anything else.
  """
  @spec date_parse(term()) :: number_value()
  def date_parse(text) when is_binary(text) do
    t = trim(text)

    cond do
      m = Regex.run(~r/\A([+-]\d{6}|\d{4})(?:-(\d\d)(?:-(\d\d))?)?\z/, t) ->
        [_, y | rest] = m
        iso_parts(y, Enum.at(rest, 0) || "01", Enum.at(rest, 1) || "01", "00", "00", "00", "", "Z")

      m =
          Regex.run(
            ~r/\A([+-]\d{6}|\d{4})-(\d\d)-(\d\d)[Tt ](\d\d):(\d\d)(?::(\d\d)(?:[.,](\d+))?)?\s*(Z|z|[+-]\d\d(?::?\d\d)?)?\z/,
            t
          ) ->
        [_, y, mo, d, h, mi | rest] = m
        s = Enum.at(rest, 0) || ""
        f = Enum.at(rest, 1) || ""
        z = Enum.at(rest, 2) || ""
        iso_parts(y, mo, d, h, mi, if(s == "", do: "00", else: s), f, if(z == "", do: "Z", else: z))

      true ->
        rfc2822(t)
    end
  end

  def date_parse(_), do: :nan

  defp iso_parts(y, mo, d, h, mi, s, f, z) do
    year = String.to_integer(y)

    {mo, d, h, mi, s} =
      {String.to_integer(mo), String.to_integer(d), String.to_integer(h), String.to_integer(mi), String.to_integer(s)}

    ms = if f == "", do: 0, else: f |> String.pad_trailing(3, "0") |> binary_part(0, 3) |> String.to_integer()

    valid =
      mo in 1..12 and d >= 1 and d <= days_in_month(year, mo) and
        (h in 0..23 or (h == 24 and mi == 0 and s == 0 and ms == 0)) and
        mi in 0..59 and s in 0..59

    if valid do
      offset = zone_offset(z)
      if offset == :bad, do: :nan, else: date_utc(year, mo - 1, d, h, mi, s, ms) - offset
    else
      :nan
    end
  end

  defp zone_offset(z) when z in ["Z", "z"], do: 0

  defp zone_offset(<<sign, hh::binary-size(2), rest::binary>>) do
    mm = String.trim_leading(rest, ":")
    mm = if mm == "", do: "00", else: mm

    with {h, ""} <- Integer.parse(hh), {m, ""} <- Integer.parse(mm), true <- h <= 23 and m <= 59 do
      (h * 60 + m) * 60_000 * if(sign == ?-, do: -1, else: 1)
    else
      _ -> :bad
    end
  end

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  defp rfc2822(t) do
    case Regex.run(
           ~r/\A(?:[A-Za-z]{3},?\s+)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d\d):(\d\d)(?::(\d\d))?\s*(GMT|UTC|Z|[+-]\d{4})?\z/,
           t
         ) do
      [_, d, mon, y | rest] ->
        month = Enum.find_index(@months, &(&1 == String.downcase(mon)))
        [h, mi | more] = rest
        s = Enum.at(more, 0) || ""
        z = Enum.at(more, 1) || "Z"
        z = if z in ["GMT", "UTC", ""], do: "Z", else: z

        if month == nil,
          do: :nan,
          else:
            iso_parts(y, pad(month + 1, 2), pad(String.to_integer(d), 2), h, mi, if(s == "", do: "00", else: s), "", z)

      _ ->
        :nan
    end
  end

  @doc "Days in a month of the proleptic Gregorian calendar."
  @spec days_in_month(integer(), 1..12) :: 28..31
  def days_in_month(y, 2), do: if(rem(y, 4) == 0 and (rem(y, 100) != 0 or rem(y, 400) == 0), do: 29, else: 28)
  def days_in_month(_y, m) when m in [4, 6, 9, 11], do: 30
  def days_in_month(_y, _m), do: 31
end
