output =
  case System.argv() do
    [path] -> Path.expand(path)
    _ -> Mix.raise("usage: mix run tooling/build_hex_docs.exs OUTPUT")
  end

docs_directory = Path.join(Path.dirname(output), ".hex-docs")
File.rm_rf!(docs_directory)
Mix.Task.run("docs", ["--output", docs_directory])

search_path = Path.wildcard(Path.join(docs_directory, "dist/search_data-*.js")) |> List.first()
"searchData=" <> search_json = File.read!(search_path)

canonical_json = fn
  value, encode when is_map(value) ->
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, item} -> Jason.encode!(key) <> ":" <> encode.(item, encode) end)
    |> then(&("{" <> &1 <> "}"))

  value, encode when is_list(value) ->
    value |> Enum.map_join(",", &encode.(&1, encode)) |> then(&("[" <> &1 <> "]"))

  value, _encode ->
    Jason.encode!(value)
end

normalized_search = "searchData=" <> canonical_json.(Jason.decode!(search_json), canonical_json)
digest = :crypto.hash(:sha256, normalized_search) |> Base.encode16() |> binary_part(0, 8)
normalized_search_path = Path.join(docs_directory, "dist/search_data-#{digest}.js")
File.rm!(search_path)
File.write!(normalized_search_path, normalized_search)
search_html = Path.join(docs_directory, "search.html")

File.write!(
  search_html,
  File.read!(search_html)
  |> String.replace(Path.basename(search_path), Path.basename(normalized_search_path))
)

files =
  Path.join(docs_directory, "**")
  |> Path.wildcard()
  |> Enum.filter(&(File.regular?(&1) && Path.extname(&1) != ".epub"))
  |> Enum.sort()
  |> Enum.map(fn path ->
    contents = File.read!(path)

    contents =
      if Path.extname(path) == ".html" do
        ~r/data-group-id="(\d+)-/
        |> Regex.scan(contents, capture: :all_but_first)
        |> Enum.map(&hd/1)
        |> Enum.uniq()
        |> Enum.with_index(1)
        |> Enum.reduce(contents, fn {group, stable}, html ->
          String.replace(html, ~s(data-group-id="#{group}-), ~s(data-group-id="g#{stable}-))
        end)
      else
        contents
      end

    {path |> Path.relative_to(docs_directory) |> String.to_charlist(), contents}
  end)

Mix.path_for(:archives)
|> Path.join("hex-*/**/ebin")
|> Path.wildcard()
|> Enum.each(&Code.append_path/1)

{:ok, archive} = :mix_hex_tarball.create_docs(files)
File.mkdir_p!(Path.dirname(output))
File.write!(output, archive)
File.rm_rf!(docs_directory)
IO.puts("built preserved Hex documentation artifact #{Path.basename(output)}")
