defmodule Schema.JsonReader do
  @moduledoc """
    Provides functions to read, parse, merge json files, and resolving the included files.
  """
  use GenServer

  alias Schema.Utils
  require Logger

  # The default location of the schema files
  @data_dir "../schema"
  @events_dir "events"
  @objects_dir "objects"

  # The schema uses JSON files
  @schema_file ".json"

  # The Schema version file
  @version_file "version.json"

  @categories_file "categories.json"
  @dictionary_file "dictionary.json"

  # The Schema extension file
  @extension_file "extension.json"

  # The include directive
  # The Schema extension type
  @extension :extension

  @include :"$include"

  def start_link(opts \\ []) do
    Logger.info(fn -> "#{inspect(__MODULE__)} start with: #{inspect(opts)}" end)
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec read_version() :: map()
  def read_version() do
    GenServer.call(__MODULE__, :read_version)
  end

  @spec read_categories() :: term()
  def read_categories() do
    GenServer.call(__MODULE__, :read_categories)
  end

  @spec read_dictionary() :: any()
  def read_dictionary() do
    GenServer.call(__MODULE__, :read_dictionary)
  end

  @spec read_objects() :: map()
  def read_objects() do
    GenServer.call(__MODULE__, :read_objects)
  end

  @spec read_classes() :: map()
  def read_classes() do
    GenServer.call(__MODULE__, :read_classes)
  end

  @spec extension() :: :ok
  def extension() do
    GenServer.cast(__MODULE__, {:extension, []})
  end

  @spec extension(String.t()) :: :ok
  def extension(name) when is_binary(name) do
    GenServer.cast(__MODULE__, {:extension, [name]})
  end

  def extension(list) when is_list(list) do
    GenServer.cast(__MODULE__, {:extension, list})
  end

  @spec cleanup() :: :ok
  def cleanup() do
    GenServer.cast(__MODULE__, :delete)
  end

  @impl true
  @spec init(String.t() | list()) :: {:ok, term()}
  def init(ext_dir) when is_binary(ext_dir) do
    init([ext_dir])
  end

  def init(ext_dir) do
    init_cache()
    home = data_dir()
    extensions = extensions(home, ext_dir)
    Logger.info(fn -> "#{inspect(__MODULE__)} schema    : #{home}" end)
    Logger.info(fn -> "#{inspect(__MODULE__)} extensions: #{inspect(extensions)}" end)
    {:ok, {home, extensions}}
  end

  @impl true
  def handle_call(:read_version, _from, {home, _ext_dir} = state) do
    {:reply, read_version(home), state}
  end

  @impl true
  def handle_call(:read_categories, _from, {home, ext_dir} = state) do
    {:reply, read_categories(home, ext_dir), state}
  end

  @impl true
  def handle_call(:read_dictionary, _from, {home, ext_dir} = state) do
    {:reply, read_dictionary(home, ext_dir), state}
  end

  @impl true
  def handle_call(:read_objects, _from, {home, ext_dir} = state) do
    {:reply, read_objects(home, ext_dir), state}
  end

  @impl true
  def handle_call(:read_classes, _from, {home, ext_dir} = state) do
    {:reply, read_classes(home, ext_dir), state}
  end

  @impl true
  def handle_cast({:extension, ext_dir}, {home, _ext_dir}) do
    {:noreply, {home, extensions(home, ext_dir)}}
  end

  @impl true
  def handle_cast(:delete, state) do
    delete()
    {:noreply, state}
  end

  defp data_dir() do
    (Application.get_env(:schema_server, __MODULE__) |> Keyword.get(:home) || @data_dir)
    |> Path.absname()
    |> Path.expand()
  end

  defp read_version(home) do
    file = Path.join(home, @version_file)

    if File.regular?(file) do
      version = read_json_file(file)
      Logger.info(fn -> "#{inspect(__MODULE__)} version: #{version.version}" end)
      version
    else
      Logger.warn("#{inspect(__MODULE__)} version file #{file} not found")
      %{"version" => "0.0.0"}
    end
  end

  defp read_categories(home, []) do
    Path.join(home, @categories_file) |> read_json_file()
  end

  defp read_categories(home, extensions) do
    categories = Path.join(home, @categories_file) |> read_json_file()

    Enum.reduce(extensions, categories, fn path, acc ->
      merge_extension(acc, "splunk", Path.join(path, @categories_file))
    end)
  end

  defp read_dictionary(home, []) do
    Path.join(home, @dictionary_file) |> read_json_file()
  end

  defp read_dictionary(home, extensions) do
    dictionary = Path.join(home, @dictionary_file) |> read_json_file()

    Enum.reduce(extensions, dictionary, fn path, acc ->
      merge_extension(acc, "splunk", Path.join(path, @dictionary_file))
    end)
  end

  defp read_objects(home, []) do
    read_schema_files(Map.new(), home, Path.join(home, @objects_dir))
  end

  defp read_objects(home, extensions) do
    objects = read_schema_files(Map.new(), home, Path.join(home, @objects_dir))

    Enum.reduce(extensions, objects, fn path, acc ->
      merge_extenstion_files(acc, home, Path.join(path, @objects_dir))
    end)
  end

  defp read_classes(home, []) do
    read_schema_files(Map.new(), home, Path.join(home, @events_dir))
  end

  defp read_classes(home, extensions) do
    events = read_schema_files(Map.new(), home, Path.join(home, @events_dir))

    Enum.reduce(extensions, events, fn path, acc ->
      merge_extenstion_files(acc, home, Path.join(path, @events_dir))
    end)
  end

  defp read_schema_files(acc, home, path) do
    if File.dir?(path) do
      Logger.info(fn -> "#{inspect(__MODULE__)} read files: #{path}" end)

      case File.ls(path) do
        {:ok, files} ->
          files
          |> Stream.map(fn file -> Path.join(path, file) end)
          |> Enum.reduce(acc, fn file, map -> read_schema_files(map, home, file) end)

        error ->
          Logger.warn("unable to access #{path} directory. Error: #{inspect(error)}")
          raise error
      end
    else
      if Path.extname(path) == @schema_file do
        data = read_json_file(path) |> resolve_includes(home)
        Map.put(acc, String.to_atom(data.type), data)
      else
        acc
      end
    end
  end

  defp read_json_file(file) do
    data = File.read!(file)

    case Jason.decode(data, keys: :atoms) do
      {:ok, json} ->
        json

      {:error, error} ->
        message = Jason.DecodeError.message(error)
        Logger.error("invalid JSON file: #{file}. Error: #{message}")
        raise message
    end
  end

  defp merge_extension(acc, extension, path) do
    if File.regular?(path) do
      Logger.info(fn -> "#{inspect(__MODULE__)} read file : #{extension} #{path}" end)

      read_json_file(path)
      |> add_extention_type(extension)
      |> Utils.deep_merge(acc)
    else
      acc
    end
  end

  defp merge_extenstion_files(acc, home, path) do
    if File.dir?(path) do
      read_schema_files(acc, home, path)
    else
      acc
    end
  end

  defp add_extention_type(map, extension) do
    Map.update!(map, :attributes, fn attributes ->
      Enum.map(attributes, fn {name, value} ->
        {name, Map.put(value, @extension, extension)}
      end)
      |> Map.new()
    end)
  end

  defp resolve_includes(data, home) do
    resolve_includes(data, Map.get(data, :attributes), home)
  end

  defp resolve_includes(data, nil, _home), do: data

  defp resolve_includes(data, attributes, home) do
    case Map.get(attributes, @include) do
      nil ->
        data

      file when is_binary(file) ->
        include_traits(home, file, data)

      files when is_list(files) ->
        Enum.reduce(files, data, fn file, acc -> include_traits(home, file, acc) end)
    end
    |> include_enums(home)
  end

  defp include_traits(home, file, data) do
    included =
      case get(file) do
        [] ->
          Path.join(home, file)
          |> read_json_file()
          |> resolve_includes(home)
          |> put(data)

        [{_, cached}] ->
          cached
      end

    attributes =
      Schema.Utils.deep_merge(included.attributes, Map.delete(data.attributes, @include))

    Map.put(data, :attributes, attributes)
  end

  defp include_enums(class, home) do
    Map.update(class, :attributes, [], fn attributes -> merge_enums(home, attributes) end)
  end

  defp merge_enums(home, attributes) do
    Enum.map(
      attributes,
      fn {name, attribute} ->
        {name, merge_enum_file(home, attribute)}
      end
    )
    |> Map.new()
  end

  defp merge_enum_file(home, attribute) do
    case Map.get(attribute, @include) do
      nil ->
        attribute

      file ->
        merge_enum_file(home, file, Map.delete(attribute, @include))
    end
  end

  defp merge_enum_file(home, file, attribute) do
    included =
      case get(file) do
        [] ->
          Path.join(home, file)
          |> read_json_file()
          |> put(file)

        [{_, cached}] ->
          cached
      end

    Schema.Utils.deep_merge(included, attribute)
  end

  defp read_extension(path) do
    file = Path.join(path, @extension_file)

    if File.regular?(file) do
      read_json_file(file)
    else
      Logger.warn("extension file #{file} not found")
      :none
    end
  end

  def extensions(_home, nil), do: []
  def extensions(_home, []), do: []

  def extensions(home, path) when is_binary(path) do
    find_extensions(home, path, [])
  end

  def extensions(home, list) when is_list(list) do
    Enum.reduce(list, [], fn path, acc ->
      find_extensions(home, path, acc)
    end)
    |> Enum.uniq()
  end

  defp find_extensions(home, path, list) do
    path =
      Path.join(home, path)
      |> Path.absname()
      |> Path.expand()

    if File.dir?(path) do
      find_extensions(path, list)
    else
      Logger.warn("invalid extensions path: #{path}")
      list
    end
  end

  defp find_extensions(path, list) do
    if File.dir?(path) do
      if extension_dir?(path) do
        [path | list]
      else
        case File.ls(path) do
          {:ok, files} ->
            files
            |> Enum.map(fn file -> Path.join(path, file) end)
            |> Enum.reduce(list, fn file, acc -> find_extensions(file, acc) end)

          error ->
            Logger.warn("unable to access #{path} directory. Error: #{inspect(error)}")
            raise error
        end
      end
    else
      list
    end
  end

  defp extension_dir?(path) do
    Path.join(path, @extension_file) |> File.regular?()
  end

  # ETS cache for the included json files
  defp init_cache() do
    name = __MODULE__

    case :ets.info(name) do
      :undefined ->
        :ets.new(name, [:set, :protected, :named_table])

      _ ->
        raise "ETS table with name #{name} already exists."
    end
  end

  defp put(data, path) do
    :ets.insert(__MODULE__, {path, data})
    data
  end

  defp get(path) do
    :ets.lookup(__MODULE__, path)
  end

  defp delete() do
    :ets.delete_all_objects(__MODULE__)
  end
end
