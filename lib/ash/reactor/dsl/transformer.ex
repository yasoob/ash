defmodule Ash.Reactor.Dsl.Transformer do
  @moduledoc false
  alias Spark.{Dsl.Transformer, Error.DslError}
  use Transformer

  def before?(Reactor.Dsl.Transformer), do: true
  def before?(_), do: false

  def after?(_), do: false

  defguardp is_action_step(module) when is_struct(module, Ash.Reactor.Dsl.Create)

  @spec transform(Spark.Dsl.t()) :: {:ok, Spark.Dsl.t()} | {:error, any}
  def transform(dsl_state) do
    with {:ok, dsl_state} <- transform_steps(dsl_state) do
      {:ok, dsl_state}
    end
  end

  defp transform_steps(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:reactor])
    |> Enum.reduce_while({:ok, dsl_state}, fn entity, {:ok, dsl_state} ->
      case transform_step(entity, dsl_state) do
        :ok ->
          {:cont, {:ok, dsl_state}}

        {:ok, entity} ->
          {:cont, {:ok, Transformer.replace_entity(dsl_state, [:reactor], entity)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp transform_step(entity, dsl_state) when is_action_step(entity) do
    with {:ok, entity} <- transform_entity_api(entity, dsl_state),
         :ok <- validate_entity_api(entity, dsl_state),
         :ok <- validate_entity_resource(entity, dsl_state),
         {:ok, action} <- get_entity_resource_action(entity, dsl_state),
         :ok <- validate_entity_inputs(entity, action, dsl_state),
         :ok <- maybe_validate_upsert_identity(entity, dsl_state),
         {:ok, entity} <- transform_nested_steps(entity, dsl_state) do
      {:ok, entity}
    end
  end

  defp transform_step(entity, dsl_state), do: transform_nested_steps(entity, dsl_state)

  defp transform_nested_steps(parent_entity, dsl_state) when is_list(parent_entity.steps) do
    parent_entity.steps
    |> Enum.reduce_while({:ok, parent_entity}, fn entity, {:ok, parent_entity} ->
      case transform_step(entity, dsl_state) do
        :ok ->
          {:cont, {:ok, %{parent_entity | steps: [entity | parent_entity.steps]}}}

        {:ok, new_entity} ->
          {:cont, {:ok, %{parent_entity | steps: [new_entity | parent_entity.steps]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp transform_nested_steps(parent_entity, _dsl_state), do: {:ok, parent_entity}

  defp transform_entity_api(entity, dsl_state) do
    default_api = Transformer.get_option(dsl_state, [:ash], :default_api)

    {:ok, %{entity | api: entity.api || default_api}}
  end

  defp validate_entity_api(entity, dsl_state) do
    if entity.api.spark_is() == Ash.Api do
      :ok
    else
      {:error,
       DslError.exception(
         module: Transformer.get_entities(dsl_state, :module),
         path: [:ash, :default_api],
         message:
           "The #{entity.type} step `#{inspect(entity.name)}` has its API set to `#{inspect(entity.api)}` but it is not a valid Ash API."
       )}
    end
  end

  defp validate_entity_resource(entity, dsl_state) do
    if entity.resource.spark_is() == Ash.Resource do
      :ok
    else
      {:error,
       DslError.exception(
         module: Transformer.get_persisted(dsl_state, :module),
         path: [:reactor, entity.type, entity.name],
         message:
           "The #{entity.type} step `#{inspect(entity.name)}` has its resource set to `#{inspect(entity.resource)}` but it is not a valid Ash resource."
       )}
    end
  end

  defp validate_entity_inputs(entity, action, dsl_state) do
    argument_names = Enum.map(action.arguments, & &1.name)

    input_names =
      entity.resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)
      |> Enum.filter(&(&1 in action.accept))
      |> Enum.reject(&(&1 in action.reject))
      |> Enum.concat(argument_names)

    entity.inputs
    |> Enum.flat_map(&Map.keys(&1.template))
    |> Enum.all?()

    :ok
  end

  defp get_entity_resource_action(entity, dsl_state) do
    case Ash.Resource.Info.action(entity.resource, entity.action, entity.type) do
      nil ->
        suggestions =
          entity.resource
          |> Ash.Resource.Info.actions()
          |> Enum.filter(&(&1.type == entity.type))
          |> Enum.map(&to_string(&1.name))
          |> sorted_suggestions(entity.action)

        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:reactor, entity.type, entity.name],
           message:
             "The #{entity.type} step `#{inspect(entity.name)}` refers to an action named `#{entity.action}` which doesn't exist." <>
               suggestions
         )}

      action ->
        {:ok, action}
    end
  end

  defp maybe_validate_upsert_identity(entity, dsl_state)
       when entity.upsert? and entity.upsert_identity do
    if Ash.Resource.Info.identity(entity.resource, entity.upsert_identity) do
      :ok
    else
      suggestions =
        entity.resource
        |> Ash.Resource.Info.identities()
        |> Enum.map(& &1.name)
        |> sorted_suggestions(entity.upsert_identity)

      {:error,
       DslError.exception(
         module: Transformer.get_persisted(dsl_state, :module),
         path: [:reactor, entity.type, entity.name],
         message:
           "The #{entity.type} step `#{inspect(entity.name)}` refers to an identity named `#{entity.upsert_identity}` but it does not exist." <>
             suggestions
       )}
    end
  end

  defp maybe_validate_upsert_identity(_entity, _dsl_state), do: :ok

  defp sorted_suggestions([], _), do: ""

  defp sorted_suggestions(suggestions, tried) do
    tried = to_string(tried)

    suggestions
    |> Enum.map(&to_string/1)
    |> Enum.sort_by(&String.jaro_distance(&1, tried))
    |> case do
      [suggestion] ->
        "\n\nDid you mean `#{suggestion}`?"

      suggestions ->
        [last | rest] = Enum.reverse(suggestions)

        rest =
          rest
          |> Enum.reverse()
          |> Enum.map_join(", ", &"`#{&1}`")

        "\n\nDid you mean #{rest} or `#{last}`?"
    end
  end
end
