defmodule Domo.TypeEnsurerFactory.DependencyResolver do
  @moduledoc false

  alias Domo.TermSerializer
  alias Domo.TypeEnsurerFactory.DependencyResolver.ElixirTask
  alias Domo.TypeEnsurerFactory.Error
  alias Domo.TypeEnsurerFactory.ModuleInspector
  alias Domo.TypeEnsurerFactory.Resolver.Fields

  def maybe_recompile_depending_structs(deps_path, preconds_path, opts) do
    file_module = opts[:file_module] || File

    with {:ok, content} <- read_deps(deps_path, file_module),
         {:ok, deps} <- decode_deps(content),
         {:ok, content} <- read_preconds(preconds_path, file_module),
         {:ok, preconds} <- decode_preconds(content),
         {:ok, updated_deps, type_hash_by_dependant_module} <- maybe_cleanup_and_write_deps(deps_path, deps, file_module),
         {:ok, updated_preconds} <- maybe_cleanup_preconds(preconds_path, preconds, file_module) do
      preconds_hash_by_module = get_precond_hashes(updated_preconds)
      maybe_recompile(updated_deps, deps, type_hash_by_dependant_module, preconds_hash_by_module, opts)
    else
      {:error, {:read_deps, :enoent}} ->
        {:ok, []}

      {:error, {operation, _message} = error} when operation in [:read_deps, :decode_deps, :update_deps] ->
        %Error{
          compiler_module: __MODULE__,
          file: deps_path,
          struct_module: nil,
          message: error
        }

      {:error, {operation, _message} = error} when operation in [:read_preconds, :decode_preconds, :update_preconds] ->
        %Error{
          compiler_module: __MODULE__,
          file: preconds_path,
          struct_module: nil,
          message: error
        }

      {:error, [_ | _]} = error ->
        error
    end
  end

  defp read_deps(deps_path, file_module) do
    case file_module.read(deps_path) do
      {:ok, _content} = ok -> ok
      {:error, message} -> {:error, {:read_deps, message}}
    end
  end

  defp read_preconds(preconds_path, file_module) do
    case file_module.read(preconds_path) do
      {:ok, _content} = ok -> ok
      {:error, message} -> {:error, {:read_preconds, message}}
    end
  end

  defp decode_deps(binary) do
    try do
      {:ok, TermSerializer.binary_to_term(binary)}
    rescue
      _error -> {:error, {:decode_deps, :malformed_binary}}
    end
  end

  defp decode_preconds(binary) do
    try do
      {:ok, TermSerializer.binary_to_term(binary)}
    rescue
      _error -> {:error, {:decode_preconds, :malformed_binary}}
    end
  end

  defp get_dependant_module_hashes(deps) do
    deps
    |> Map.values()
    |> Enum.flat_map(fn {_path, module_type_hash_list} -> module_type_hash_list end)
    |> Enum.uniq()
    |> Enum.map(fn {module, _type_old_hash, _precond_old_hash} ->
      {module, ModuleInspector.beam_types_hash(module)}
    end)
    |> Enum.into(%{})
  end

  defp get_precond_hashes(preconds) do
    preconds
    |> Enum.map(fn {module, types_precond_description} ->
      {module, Fields.preconditions_hash(types_precond_description)}
    end)
    |> Enum.into(%{})
  end

  defp maybe_cleanup_and_write_deps(deps_path, deps, file_module) do
    loadable_deps = remove_unloadable_modules(deps)
    type_hash_by_dependant_module = get_dependant_module_hashes(loadable_deps)
    updated_deps = remove_modules_with_unloadable_types(loadable_deps, type_hash_by_dependant_module)

    if updated_deps == deps do
      {:ok, updated_deps, type_hash_by_dependant_module}
    else
      case file_module.write(deps_path, TermSerializer.term_to_binary(updated_deps)) do
        :ok -> {:ok, updated_deps, type_hash_by_dependant_module}
        {:error, message} -> {:error, {:update_deps, message}}
      end
    end
  end

  defp maybe_cleanup_preconds(preconds_path, preconds, file_module) do
    updated_preconds =
      Enum.reduce(preconds, %{}, fn {module, type_precond_description}, map ->
        if Code.ensure_loaded?(module) and Kernel.function_exported?(module, :__precond__, 2) do
          Map.put(map, module, type_precond_description)
        else
          map
        end
      end)

    if map_size(updated_preconds) != map_size(preconds) do
      case file_module.write(preconds_path, TermSerializer.term_to_binary(updated_preconds)) do
        :ok -> {:ok, updated_preconds}
        {:error, message} -> {:error, {:update_preconds, message}}
      end
    else
      {:ok, preconds}
    end
  end

  defp remove_unloadable_modules(deps) do
    Enum.reduce(deps, %{}, fn {module, {path, dependants}}, acc ->
      if Code.ensure_loaded?(module) do
        updated_dependants = remove_unloadable_dependant_modules(dependants)
        Map.put(acc, module, {path, updated_dependants})
      else
        acc
      end
    end)
  end

  defp remove_unloadable_dependant_modules(dependants) do
    Enum.filter(dependants, fn {dependant_module, _type_old_hash, _precond_old_hash} ->
      Code.ensure_loaded?(dependant_module)
    end)
  end

  defp remove_modules_with_unloadable_types(deps, type_hash_by_dependant_module) do
    Enum.reduce(deps, %{}, fn {module, {path, dependants}}, acc ->
      if ModuleInspector.beam_types_hash(module) == nil do
        acc
      else
        updated_dependants =
          remove_dependant_modules_with_unloadable_types(
            dependants,
            type_hash_by_dependant_module
          )

        Map.put(acc, module, {path, updated_dependants})
      end
    end)
  end

  defp remove_dependant_modules_with_unloadable_types(dependants, type_hashes_by_module) do
    dependants
    |> Enum.reduce([], fn {dependant_module, _type_old_hash, _precond_old_hash} = dependent, acc ->
      if type_hashes_by_module[dependant_module] == nil do
        acc
      else
        [dependent | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp maybe_recompile(updated_deps, deps, type_hash_by_dependant_module, preconds_hash_by_module, opts) do
    {modules_to_recompile, sources_to_recompile} =
      updated_deps
      |> sources_with_changed_dependants_type_hash(type_hash_by_dependant_module)
      |> add_sources_for_modules_of_changed_dependants(updated_deps, deps)
      |> add_sources_for_modules_of_changed_preconditions(updated_deps, preconds_hash_by_module)
      |> add_sources_dependind_on_changed_sources(deps)
      |> Enum.unzip()

    if Enum.empty?(sources_to_recompile) do
      {:ok, []}
    else
      sources_to_recompile = Enum.uniq(sources_to_recompile)
      beams_to_recompile = beams_compiled_from_sources(Enum.uniq(modules_to_recompile), sources_to_recompile, opts)

      touch_and_recompile(sources_to_recompile, beams_to_recompile, opts[:verbose?] || false)
    end
  end

  # Elixir checks one module of a source to decide whether to rebuild it, see
  # missing_beam_file?/2 in Mix.Compilers.Elixir. Removing the BEAM of a module
  # nested into another module's file leaves that one in place, so the source is
  # never rebuilt - hence removals are derived from sources, not from modules.
  defp beams_compiled_from_sources(modules, sources, opts) do
    module_beams = Enum.flat_map(modules, &module_beam_path/1)
    sibling_beams = beams_with_source_in(sources, ebin_paths(module_beams, opts))

    Enum.uniq(module_beams ++ sibling_beams)
  end

  defp module_beam_path(module) do
    case :code.which(module) do
      # in memory, preloaded, cover compiled or not found modules have no BEAM file
      path when is_list(path) and path != [] -> [List.to_string(path)]
      _no_beam_file -> []
    end
  end

  defp ebin_paths(module_beams, opts) do
    # Both callers run under the Mix compiler, so a project is always in scope.
    compile_path = opts[:compile_path] || Mix.Project.compile_path()

    [compile_path | Enum.map(module_beams, &Path.dirname/1)]
    |> Enum.uniq()
  end

  defp beams_with_source_in(sources, ebin_paths) do
    source_set = MapSet.new(sources, &Path.expand/1)

    ebin_paths
    |> Enum.flat_map(&beam_files_in/1)
    |> Enum.filter(fn beam_path ->
      source = beam_source(beam_path)
      not is_nil(source) and MapSet.member?(source_set, source)
    end)
  end

  defp beam_files_in(ebin_path) do
    case File.ls(ebin_path) do
      {:ok, entries} -> for entry <- entries, String.ends_with?(entry, ".beam"), do: Path.join(ebin_path, entry)
      {:error, _reason} -> []
    end
  end

  defp beam_source(beam_path) do
    case :beam_lib.chunks(String.to_charlist(beam_path), [:compile_info]) do
      {:ok, {_module, [compile_info: compile_info]}} -> compile_info |> compile_info_source() |> expand_source()
      _error -> nil
    end
  end

  defp compile_info_source(compile_info) when is_list(compile_info), do: Keyword.get(compile_info, :source)
  defp compile_info_source(_compile_info), do: nil

  defp expand_source(source) when is_list(source) and source != [], do: source |> List.to_string() |> Path.expand()
  defp expand_source(_source), do: nil

  defp sources_with_changed_dependants_type_hash(deps, dependant_module_type_hashes) do
    Enum.reduce(deps, %{}, fn {module, {path, dependants}}, acc ->
      if any_type_hash_changed?(dependants, dependant_module_type_hashes) do
        Map.put(acc, module, path)
      else
        acc
      end
    end)
  end

  defp any_type_hash_changed?(dependants, dependant_module_type_hashes) do
    Enum.any?(dependants, fn {module, old_hash, _precond_old_hash} ->
      new_hash = dependant_module_type_hashes[module]
      old_hash != new_hash
    end)
  end

  defp add_sources_for_modules_of_changed_dependants(sources_by_module, updated_deps, deps) do
    changed_sources =
      Enum.reduce(updated_deps, %{}, fn {module, {path, dependants}}, acc ->
        {_path, original_dependants} = deps[module]

        if original_dependants != dependants do
          Map.put(acc, module, path)
        else
          acc
        end
      end)

    Map.merge(sources_by_module, changed_sources)
  end

  defp add_sources_for_modules_of_changed_preconditions(sources_by_module, updated_deps, preconds_hash_by_module) do
    changed_sources =
      Enum.reduce(updated_deps, %{}, fn {module, {path, dependants}}, acc ->
        any_hash_differs? = Enum.any?(dependants, fn {module, _type_hash, preconds_hash} -> preconds_hash != preconds_hash_by_module[module] end)

        if any_hash_differs? do
          Map.put(acc, module, path)
        else
          acc
        end
      end)

    Map.merge(sources_by_module, changed_sources)
  end

  defp add_sources_dependind_on_changed_sources(source_by_module_to_recompile, deps) do
    updated_map = do_add_sources_dependind_on_changed_sources(source_by_module_to_recompile, deps)

    if updated_map != source_by_module_to_recompile do
      add_sources_dependind_on_changed_sources(updated_map, deps)
    else
      updated_map
    end
  end

  defp do_add_sources_dependind_on_changed_sources(source_by_module_to_recompile, deps) do
    Enum.reduce(deps, source_by_module_to_recompile, fn
      {module, {source_path, dependants}}, acc ->
        Enum.reduce(dependants, acc, fn {dependant_module, _type_old_hash, _precond_old_hash}, acc ->
          maybe_add_moudle_path(acc, module, source_path, dependant_module)
        end)
    end)
  end

  defp maybe_add_moudle_path(acc, module, source_path, dependant_module) do
    if Map.has_key?(acc, dependant_module) do
      Map.put(acc, module, source_path)
    else
      acc
    end
  end

  defp touch_and_recompile(sources_to_recompile, beams_to_recompile, verbose?) do
    # Have to wait 1 second to touch files with later epoch time
    # and make elixir compiler to percept them as stale files.
    Process.sleep(1000)

    if verbose? do
      IO.puts("""
      Domo marks files for recompilation by touching:
      #{Enum.join(sources_to_recompile, "\n")}\
      """)
    end

    Enum.each(sources_to_recompile, &File.touch!/1)

    if verbose? do
      IO.puts("""
      Domo meets Elixir's criteria for recompilation by removing:
      #{Enum.join(beams_to_recompile, "\n")}\
      """)
    end

    # Since v1.13 Elixir expects missing .beam to recompile from source
    Enum.each(beams_to_recompile, &File.rm/1)

    ElixirTask.recompile_with_elixir(verbose?)
  end
end
