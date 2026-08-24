defmodule MixWorkspaceOps.Registry.Examples do
  @moduledoc """
  Validates the catalog examples a documentation file carries.

  A guide's examples are worth what a reader can do with them. An example the
  validator refuses teaches a shape that cannot be catalogued, and the reader who
  copies it learns that only from the error. So the examples are read out of the
  file, assembled, and held to the same contract as a catalog on disk.

  Three kinds of fenced `json` block are recognised. A block carrying a catalog
  `schema` is a whole document and must be valid exactly as it stands. A block
  carrying a view schema is a view document and is loaded as one. Every other
  block carries an `id` and is a repository record — complete, or carrying only
  the fields its passage is about; records are merged by `id`, nested objects
  merged and everything else replaced, into the one document the guide describes.
  That document must load, and its release train must derive.
  """

  alias MixWorkspaceOps.{Registry, StrictJSON, View}
  alias MixWorkspaceOps.Registry.{Document, ReleaseChain}

  @fence ~r/^```json[ \t]*\n(.*?)\n```[ \t]*$/ms

  @doc "Validates every catalog example in the documentation file at `path`."
  @spec validate(String.t()) :: {:ok, map()} | {:error, term()}
  def validate(path) do
    path = Path.expand(path)

    with {:ok, source} <- File.read(path),
         {:ok, blocks} <- blocks(source, path),
         {:ok, state} <- assemble(blocks, path),
         {:ok, registry} <- load_assembled(state, path),
         {:ok, chain} <- ReleaseChain.derive(registry) do
      {:ok, report(path, state, registry, chain)}
    end
  end

  defp blocks(source, path) do
    case Regex.scan(@fence, source, capture: :all_but_first) do
      [] -> {:error, {:no_examples, path}}
      matches -> {:ok, matches |> Enum.map(&hd/1) |> Enum.with_index(1)}
    end
  end

  defp assemble(blocks, path) do
    initial = %{
      schema: Document.current_schema(),
      records: [],
      examples: length(blocks),
      documents: 0,
      views: 0,
      fields: 0
    }

    Enum.reduce_while(blocks, {:ok, initial}, fn {body, index}, {:ok, state} ->
      case place(body, index, state, path) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp place(body, index, state, path) do
    case StrictJSON.decode(body) do
      {:ok, %{"schema" => schema} = document} ->
        if schema in View.schemas(),
          do: view(document, index, state, path),
          else: document(document, schema, index, state, path)

      {:ok, %{"id" => id} = record} when is_binary(id) ->
        {:ok, %{state | records: merge(state.records, record), fields: state.fields + 1}}

      {:ok, _other} ->
        {:error, {:unaddressed_example, index}}

      {:error, reason} ->
        {:error, {:invalid_example, index, reason}}
    end
  end

  # A block claiming to be a whole document is held to that claim on its own,
  # before it contributes anything to the document the guide assembles.
  defp document(raw, schema, index, state, path) do
    case Registry.load_document(encode(raw), path) do
      {:ok, _registry} ->
        {:ok,
         %{
           state
           | schema: schema,
             records:
               Enum.reduce(Map.get(raw, "repositories", []), state.records, &merge(&2, &1)),
             documents: state.documents + 1
         }}

      {:error, reason} ->
        {:error, {:invalid_example, index, reason}}
    end
  end

  defp view(raw, index, state, path) do
    case View.load_document(encode(raw), path) do
      {:ok, _view} -> {:ok, %{state | views: state.views + 1}}
      {:error, reason} -> {:error, {:invalid_example, index, reason}}
    end
  end

  defp merge(records, record) do
    if Enum.any?(records, &(&1["id"] == record["id"])),
      do: Enum.map(records, &merge_matching(&1, record)),
      else: records ++ [record]
  end

  defp merge_matching(existing, record) do
    if existing["id"] == record["id"], do: deep_merge(existing, record), else: existing
  end

  defp deep_merge(existing, addition) do
    Map.merge(existing, addition, fn
      _key, %{} = old, %{} = new -> deep_merge(old, new)
      _key, _old, new -> new
    end)
  end

  defp load_assembled(state, path) do
    %{"schema" => state.schema, "repositories" => state.records}
    |> encode()
    |> Registry.load_document(path)
  end

  defp report(path, state, registry, chain) do
    %{
      schema: "mix_workspace_ops.examples/v1",
      guide: path,
      document_schema: state.schema,
      examples: state.examples,
      documents: state.documents,
      views: state.views,
      records: state.fields,
      repositories: length(state.records),
      projects: map_size(registry.projects),
      applications: map_size(registry.applications),
      workspaces: length(Registry.workspaces(registry)),
      release_packages: map_size(chain)
    }
  end

  defp encode(document), do: document |> :json.encode() |> IO.iodata_to_binary()
end
