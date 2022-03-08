# Copyright 2021 Splunk Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
defmodule Schema do
  @moduledoc """
  Schema keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
  alias Schema.Repo
  alias Schema.Cache
  alias Schema.Utils

  @dialyzer :no_improper_lists

  @doc """
    Returns the schema version string.
  """
  @spec version :: String.t()
  def version(), do: Repo.version()

  @doc """
    Returns the event extensions.
  """
  @spec extensions :: map()
  def extensions(), do: Cache.extensions()

  @doc """
    Reloads the event schema without the extensions.
  """
  @spec reload() :: :ok
  def reload(), do: Repo.reload()

  @doc """
    Reloads the event schema with extensions from the given path.
  """
  @spec reload(String.t() | list()) :: :ok
  def reload(path), do: Repo.reload(path)

  @doc """
    Returns the event categories.
  """
  @spec categories :: map()
  def categories(), do: Repo.categories()

  @doc """
    Returns the event categories defined in the given extension set.
  """
  @spec categories(Repo.extensions()) :: map()
  def categories(extensions), do: Repo.categories(extensions)

  @doc """
    Returns a single category with its classes.
  """
  @spec category(atom | String.t()) :: nil | Cache.category_t()
  def category(id) when is_atom(id), do: get_category(id)
  def category(id) when is_binary(id), do: get_category(Utils.to_uid(id))

  @spec category(Repo.extensions(), String.t(), String.t()) :: nil | Cache.category_t()
  def category(extensions, extension, id),
    do: get_category(extensions, Utils.to_uid(extension, id))

  @doc """
    Returns the attribute dictionary.
  """
  @spec dictionary() :: Cache.dictionary_t()
  def dictionary(), do: Repo.dictionary()

  @doc """
    Returns the attribute dictionary including the extension.
  """
  @spec dictionary(Repo.extensions()) :: Cache.dictionary_t()
  def dictionary(extensions), do: Repo.dictionary(extensions)

  @doc """
    Returns all event classes.
  """
  @spec classes() :: map()
  def classes(), do: Repo.classes()

  @spec classes(Repo.extensions()) :: map()
  def classes(extensions), do: Repo.classes(extensions)

  @doc """
    Returns a single event class.
  """
  @spec class(atom | String.t()) :: nil | Cache.class_t()
  def class(id) when is_binary(id), do: Repo.class(Utils.to_uid(id))
  def class(id) when is_atom(id), do: Repo.class(id)

  @spec class(nil | String.t(), String.t()) :: nil | map()
  def class(extension, id) when is_binary(id),
    do: Repo.class(Utils.to_uid(extension, id))

  @doc """
  Finds a class by the class uid value.
  """
  @spec find_class(integer()) :: nil | Cache.class_t()
  def find_class(uid) when is_integer(uid), do: Repo.find_class(uid)

  @doc """
    Returns all objects.
  """
  @spec objects() :: map()
  def objects(), do: Repo.objects()

  @spec objects(Repo.extensions()) :: map()
  def objects(extensions), do: Repo.objects(extensions)

  @doc """
    Returns a single objects.
  """
  @spec object(atom | String.t()) :: nil | Cache.object_t()
  def object(id) when is_binary(id), do: Repo.object(Utils.to_uid(id))
  def object(id) when is_atom(id), do: Repo.object(id)

  @spec object(nil | String.t(), String.t()) :: nil | map()
  def object(extension, id) when is_binary(id),
    do: Repo.object(Utils.to_uid(extension, id))

  @doc """
  Returns a randomly generated sample event.
  """
  @spec event(atom() | map()) :: nil | map()
  def event(class) when is_atom(class) do
    Schema.class(class) |> Schema.Generator.event()
  end

  def event(class) when is_map(class) do
    Schema.Generator.event(class)
  end

  @doc """
  Returns a randomly generated sample data.
  """
  @spec generate(map()) :: any()
  def generate(type) when is_map(type) do
    Schema.Generator.generate(type)
  end

  @spec schema_map(Repo.extensions()) :: %{
          :children => list,
          :value => non_neg_integer,
          optional(any) => any
        }
  def schema_map(extensions) do
    base = Repo.class(:base_event) |> delete_attributes()

    categories =
      Stream.map(
        Map.get(Repo.categories(extensions), :attributes),
        fn {name, _} ->
          {classes, cat} = Repo.category(name) |> Map.pop(:classes)

          children =
            classes
            |> Stream.filter(fn {_name, class} ->
              extension = class[:extension]
              extension == nil or MapSet.member?(extensions, extension)
            end)
            |> Stream.map(fn {_name, class} ->
              reduce_class(class) |> Map.put(:value, map_size(class[:attributes]))
            end)
            |> Enum.sort(fn map1, map2 -> map1[:name] <= map2[:name] end)

          Map.put(cat, :type, name)
          |> Map.put(:children, children)
          |> Map.put(:value, length(children))
        end
      )
      |> Enum.sort(fn map1, map2 -> map1[:name] <= map2[:name] end)

    base
    |> Map.put(:children, categories)
    |> Map.put(:value, length(categories))
  end

  defp get_category(id) do
    Repo.category(id) |> reduce_category()
  end

  defp get_category(extensions, id) do
    Repo.category(extensions, id) |> reduce_category()
  end

  defp reduce_category(data) do
    Map.update(data, :classes, [], fn classes ->
      Enum.map(classes, fn {name, class} ->
        {name, reduce_class(class)}
      end)
      |> Map.new()
    end)
  end

  @spec reduce_class(map) :: map
  def reduce_class(data) do
    delete_attributes(data) |> delete_see_also()
  end

  @spec delete_attributes(map) :: map
  def delete_attributes(data) do
    Map.delete(data, :attributes)
  end

  @spec delete_see_also(map) :: map
  def delete_see_also(data) do
    Map.delete(data, :see_also)
  end
end
