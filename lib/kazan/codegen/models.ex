defmodule Kazan.Codegen.Models do
  @moduledoc false
  #Macros for generating client code from OAI specs.
  require EEx

  alias Kazan.Codegen.Models.ModelDesc

  @doc """
  Generates structs for all the data definitions in an OAPI spec.

  This will read the provided file at compile time and use it to generate a
  struct for each data definition. The structs will be named as they are in the
  provided file.

  It will also generate some model description data that can be used to write
  serializers/deserializers for each of the structs.
  """
  defmacro from_spec(spec_file) do
    models = parse_models(spec_file)

    spec_forms = for {module_name, desc} <- models do
      property_names = Map.keys(desc.properties)

      documentation = model_docs(desc.description, desc.properties)

      quote do
        defmodule unquote(module_name) do
          @moduledoc unquote(documentation)

          defstruct unquote(property_names)
        end
      end
    end

    quote do
      Module.put_attribute(__MODULE__, :external_resource, unquote(spec_file))

      unquote_splicing(spec_forms)

      def model_descs do
        unquote(Macro.escape(models))
      end
    end
  end

  @doc """
  Builds a module name atom from a OAI model name.
  """
  @spec module_name(String.t) :: atom
  def module_name(model_name) do
    fixed_name =
      model_name
      |> String.split(".")
      |> Enum.map(fn (str) ->
      {first, rest} = String.Casing.titlecase_once(str)
      first <> rest
    end)
    |> Enum.join(".")

    Module.concat(Kazan.Models, fixed_name)
  end

  @doc """
  Parses a $ref for a definition into a models module name.
  """
  @spec parse_definition_ref(String.t) :: nil | :atom
  def parse_definition_ref(nil), do: nil
  def parse_definition_ref("#/definitions/" <> model_def) do
    module_name(model_def)
  end

  @doc """
  Builds an atom property name from an OAI property name.
  """
  @spec property_name(String.t) :: atom
  def property_name(str) do
    str |> Macro.underscore |> String.to_atom
  end

  @spec parse_models(String.t) :: [ModelDesc.t]
  defp parse_models(spec_file) do
    definitions =
      spec_file
      |> File.read!
      |> Poison.decode!
      |> Map.get("definitions")

    # Most of the top-level definitions in the kube spec are models.
    # However, there are a few that are used in $ref statements to define common
    # property types instead.
    # We can tell these apart by whether or not they have "properties" or not.
    is_model = fn {_, model} -> Map.has_key?(model, "properties") end

    refs =
      definitions
      |> Enum.reject(is_model)
      |> Enum.map(fn {name, data} -> {module_name(name), data} end)
      |> Enum.into(%{})

    definitions
    |> Enum.filter(is_model)
    |> Enum.map(&ModelDesc.from_oai_desc(&1, refs))
    |> Enum.map(fn (desc) -> {desc.module_name, desc} end)
    |> Enum.into(%{})
  end

  EEx.function_from_string(:defp, :model_docs, """
  <%= model_description %>

  ### Properties

  <%= for {name, property} <- properties do %>
  * `<%= name %>` <%= if doc = property_type_doc(property) do %>:: <%= doc %> <% end %>
      * <%= process_description(property.description) %> <% end %>
  """, [:model_description, :properties])

  # Creates a property type doc string.
  @spec property_type_doc(Property.t) :: String.t | nil
  defp property_type_doc(property) do
    if property.ref do
      "`#{doc_ref(property.ref)}`"
    else
      case property.type do
        "array" -> "[ #{property_type_doc(property.items)} ]"
        "integer" -> "`Integer`"
        "number" -> "`Float`"
        "object" -> "`Map`"
        "string" -> case property.format do
                      "date" -> "`Date`"
                      "date-time" -> "`DateTime`"
                      _ -> "`String`"
                    end
        "boolean" -> "`Boolean`"
      end
    end
  end

  # Pre-processes a fields description.
  # Useful for making actual links out of HTTP links etc.
  @spec process_description(String.t) :: String.t
  defp process_description(nil), do: ""
  defp process_description(desc) do
    String.replace(
      desc, ~r{ (more info): (https?://.*)(\s|$)}i, " [\\1](\\2)."
    )
  end

  # Strips the `Elixir.` prefix from an atom for use in documentation.
  # Atoms will not be linked if they include the Elixir. prefix.
  defp doc_ref(str) do
    str |> Atom.to_string |> String.replace(~r/^Elixir./, "")
  end
end
