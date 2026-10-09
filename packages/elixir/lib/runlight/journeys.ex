defmodule Runlight.Journeys do
  @moduledoc false
  # Internal. Journeys: the paths visits take through a site, page by page
  # (the SDK's journeys.ts). Each visit's pages are read in order, a page seen
  # twice in a row (a refresh) counts once, and the path is cut to a number of
  # steps, from a start page and to an end page when those are chosen. The
  # answer lines the paths up in columns, one per step, with the flows between
  # them.

  alias Runlight.JS

  @top 8

  @doc "How many pages of a visit to read: enough to find a start page and still have the steps after it."
  def pages_per_visit, do: 40

  @doc """
  Journeys from rows `%{session, path}` in order. Options: `:steps`,
  `:start`, `:end`, and `:through` (`{step, value}`, 0-based). The answer is
  a JavaScript object: visits, columns, links, and paths.
  """
  @spec journeys([map()], map()) :: Runlight.JS.Object.t()
  def journeys(rows, options) do
    steps =
      case options[:steps] |> JS.nullish(5) |> JS.number() |> JS.floor() do
        :infinity -> 8
        :neg_infinity -> 2
        n when is_integer(n) and n != 0 -> n |> max(2) |> min(8)
        _ -> 5
      end

    # Group each visit's pages, dropping refreshes.
    {order, visits} =
      Enum.reduce(rows, {[], %{}}, fn row, {order, visits} ->
        {order, pages} =
          case Map.fetch(visits, row.session) do
            {:ok, pages} -> {order, pages}
            :error -> {[row.session | order], []}
          end

        pages = if List.first(pages) == row.path, do: pages, else: [row.path | pages]
        {order, Map.put(visits, row.session, pages)}
      end)

    # Each sequence with whether its visit went on past the last step shown, so it never counts as having gone no further.
    sequences =
      order
      |> Enum.reverse()
      |> Enum.flat_map(fn session ->
        pages = Enum.reverse(Map.fetch!(visits, session))

        with {:ok, pages} <- from_start(pages, options[:start]),
             {:ok, pages} <- to_end(pages, options[:end]) do
          more = length(pages) > steps
          pages = Enum.take(pages, steps)

          case options[:through] do
            {step, value} ->
              if is_integer(step) and step >= 0 and Enum.at(pages, step) == value, do: [{pages, more}], else: []

            _ ->
              [{pages, more}]
          end
        else
          _ -> []
        end
      end)

    {columns, kept} =
      Enum.reduce_while(0..(steps - 1), {[], []}, fn i, {columns, kept} ->
        {counts, reached, left} =
          Enum.reduce(sequences, {%{}, 0, 0}, fn {s, more}, {counts, reached, left} ->
            if length(s) <= i do
              {counts, reached, left}
            else
              left = if length(s) == i + 1 and not more, do: left + 1, else: left
              {Map.update(counts, Enum.at(s, i), 1, &(&1 + 1)), reached + 1, left}
            end
          end)

        sorted =
          Enum.sort(Map.to_list(counts), fn {a, x}, {b, y} ->
            if x != y, do: x > y, else: JS.less?(a, b)
          end)

        top = Enum.take(sorted, @top)
        rest = sorted |> Enum.drop(@top) |> Enum.reduce(0, fn {_, v}, n -> n + v end)
        kept = kept ++ [MapSet.new(Enum.map(top, &elem(&1, 0)))]

        if reached == 0 do
          {:halt, {columns, kept}}
        else
          items = Enum.map(top, fn {value, visits} -> JS.obj(value: value, visits: visits) end)
          items = if rest > 0, do: items ++ [JS.obj(value: "", visits: rest)], else: items
          {:cont, {columns ++ [JS.obj(items: items, visits: reached, left: left)], kept}}
        end
      end)

    ncols = length(columns)

    links =
      sequences
      |> Enum.reduce({[], %{}}, fn {s, _}, acc ->
        s
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {[a, b], i}, {order, counts} ->
          if i + 1 < ncols do
            from = if MapSet.member?(Enum.at(kept, i), a), do: a, else: ""
            to = if MapSet.member?(Enum.at(kept, i + 1), b), do: b, else: ""
            key = {i, from, to}

            case counts do
              %{^key => n} -> {order, %{counts | key => n + 1}}
              _ -> {[key | order], Map.put(counts, key, 1)}
            end
          else
            {order, counts}
          end
        end)
      end)
      |> then(fn {order, counts} -> Enum.map(Enum.reverse(order), &{&1, counts[&1]}) end)
      # Ties go by page, as the columns and paths do, so the order never follows the visits' random ids.
      |> Enum.sort(fn {{s1, f1, t1}, v1}, {{s2, f2, t2}, v2} ->
        cond do
          s1 != s2 -> s1 < s2
          v1 != v2 -> v1 > v2
          f1 != f2 -> JS.less?(f1, f2)
          t1 != t2 -> JS.less?(t1, t2)
          true -> true
        end
      end)
      |> Enum.map(fn {{step, from, to}, visits} -> JS.obj(step: step, from: from, to: to, visits: visits) end)

    paths =
      sequences
      |> Enum.reduce({[], %{}}, fn {s, _}, {order, counts} ->
        key = Enum.join(s, <<0>>)

        case counts do
          %{^key => {pages, n}} -> {order, %{counts | key => {pages, n + 1}}}
          _ -> {[key | order], Map.put(counts, key, {s, 1})}
        end
      end)
      |> then(fn {order, counts} -> Enum.map(Enum.reverse(order), &{&1, counts[&1]}) end)
      |> Enum.sort(fn {a, {_, x}}, {b, {_, y}} -> if x != y, do: x > y, else: JS.less?(a, b) end)
      |> Enum.map(fn {_, {pages, visits}} -> JS.obj(pages: pages, visits: visits) end)
      |> Enum.take(20)

    JS.obj(visits: length(sequences), columns: columns, links: links, paths: paths)
  end

  defp from_start(pages, start) when start in [nil, ""], do: {:ok, pages}

  defp from_start(pages, start) do
    case Enum.find_index(pages, &(&1 == start)) do
      nil -> :skip
      at -> {:ok, Enum.drop(pages, at)}
    end
  end

  defp to_end(pages, finish) when finish in [nil, ""], do: {:ok, pages}

  defp to_end(pages, finish) do
    case Enum.find_index(pages, &(&1 == finish)) do
      nil -> :skip
      at -> {:ok, Enum.take(pages, at + 1)}
    end
  end
end
