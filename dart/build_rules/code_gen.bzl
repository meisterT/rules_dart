"""Defines the dart_code_gen build rule.

This rule can be used to run generators as bazel rules.

The attributes are as follows:

- deps_filter: Optional. Filters the deps to only include files matching one of
  the provided extensions. This can help with preventing cascading rebuilds due
  to overdeclared deps.
- forced_deps: Optional. Just like deps except the deps_filter will not be
  applied. This is typically used in combination with a deps_filter to allow
  certain files through that would usually be filtered out.
- generator: A dart_binary build rule which generates dart files.
- generator_args: Arbitrary arguments which can be passed to your generator.
- in_extension: All srcs with this file extension must generate outputs as
  determined by out_extensions.
- log_out_breaks_caching: Any transformer info and warnings are written to a
  file, which is available in local builds but by default is not an "official"
  rule output because it is not reproducible and thus breaks bazel caching. If a
  value for this parameter is provided, the logs will be available after the
  build as a first-class output.
  **Please do not check in rules with this value set**.
- mnemonic: Optional. The mnemonic to use for skylark actions generated by this
  rule. Specifying a custom name allows users to target this action with the
  "--strategy" option.
- out_extensions: For each src with in_extension, a file with each of these
  extensions must be output.
- supports_worker: Optional. Enabling this allows the skylark actions generated
  by this rule to run in a worker thread. This can significantly reduce
  incremental build times, but must also be opted into by the developer using
  "--strategy=$mnemonic=worker".

**IMPORTANT**: If you need to depend on the output of a dart_code_gen rule by
file path (for instance if its the script_file of a dart_binary or
dart_application rule), then you must provide the file path directly to the
srcs attribute. If it is provided using a label (like a filegroup or
dart_library) then the file will still be generated but bazel will not know
which rule generates the file.
"""

def _filter_files(filetypes, files):
  """Filters a list of files based on a list of strings."""
  filtered_files = []
  for file_to_filter in files:
    for filetype in filetypes:
      if str(file_to_filter).endswith(filetype):
        filtered_files.append(file_to_filter)
        break

  return filtered_files

def _args_file(ctx, arguments):
  """Creates a file containing all arguments, one on each line.

  Returns:
    The File object which was created.

    See [http://go/skylark] File documentation for information on File objects.
  """
  args_file = ctx.new_file(ctx.configuration.genfiles_dir,
                           "%s_%s" % (ctx.label.name, "args"))
  ctx.file_action(output=args_file, content="\n".join(arguments))
  return args_file

def _inputs_tmp_file(ctx, file_sequence, file_suffix):
  """Creates a file containing path information for files in file_sequence.

  Args:
    ctx: The context.
    file_sequence: A sequence of File objects.
    file_suffix: The suffix to use when naming the temporary file. The file will
        be prefixed with the build label name and an underscore.

  Returns:
    A File object containing one line per file in file_sequence

    See [http://go/skylark] File documentation for information on File objects.
  """
  tmp_file = ctx.new_file(ctx.configuration.genfiles_dir,
                          "%s_%s" % (ctx.label.name, file_suffix))
  paths = [f.short_path for f in file_sequence]
  ctx.file_action(output=tmp_file, content="\n".join(paths))
  return tmp_file

def _declare_outs(ctx, in_extension, out_extensions):
  """Declares the outs for a generator.

  This declares one outfile per entry in out_extensions for each file in
  ctx.files.srcs which ends with in_extension.

  Example:
  ctx.files.srcs = ["a.dart", "b.css"]
  in_extension = ".dart"
  out_extensions = [".g.dart", ".info.xml"]

  outs => ["a.g.dart", "a.info.xml"]

  Args:
    ctx: The context.
    in_extension: The file extension to process.
    out_extensions: One or more output extensions that should be emitted.

  Returns:
    A sequence of File objects which will be emitted.
  """
  if not ctx.files.srcs:
    fail("must not be empty", attr="srcs")
  if not out_extensions:
    fail("must not be empty", attr="out_extensions")

  outs = []
  for src in ctx.files.srcs:
    if (src.basename.endswith(in_extension)):
      for ext in out_extensions:
        out_name = "%s%s" % (src.basename[:-1 * len(in_extension)], ext)
        output = ctx.new_file(src, out_name)
        outs.append(output)
  return outs

def _compute_outs(in_extension, out_extensions, srcs):
  """Computes the expected outputs.

  This uses roughly the same logic as _declare_outs
  except it uses the attributes only and is called in the first bazel phase.

  **NOTE**: Because you cannot expand the `srcs` in this phase this will only
  declare outputs for explicitly supplied files, not labels. This only matters
  if you want to depend directly on the outputs of this rule in other bazel
  rules by their file path.

  Args:
    in_extension: string
    out_extensions: list of strings
    srcs: list of Files

  Returns:
    A map which is used as the rules `outputs`.
  """
  if not srcs:
    fail("must not be empty", attr="srcs")
  if not out_extensions:
    fail("must not be empty", attr="out_extensions")

  outs = {}
  for label in srcs:
    if label.name.endswith(in_extension):
      for ext in out_extensions:
        out_name = "%s%s" % (label.name[:-1 * len(in_extension)], ext)
        outs[out_name] = out_name
  return outs

def _get_mnemonic(ctx):
  # Gets the name for this bazel action. This can be used to enable/disable
  # running actions with different strategies. We use "DartSourceGenNonworker"
  # as the default, and "DartSourceGen" for actions which explicitly declare
  # worker support. This can also be overriden using the `mnemonic` attribute.
  #
  # You can enable bazel workers by adding "--strategy=DartSourceGen=worker"
  # to your either your .bazelrc file or as a command line argument.
  if ctx.attr.mnemonic:
    return ctx.attr.mnemonic
  elif ctx.attr.supports_worker:
    return "DartSourceGen"
  else:
    return "DartSourceGenNonworker"

def _code_gen_impl(ctx):
  """Invokes ctx.generator with arguments provided to the rule.

  Args:
    ctx: A context.

  Returns:
    A struct containing files output.
  """

  in_extension = ctx.attr.in_extension
  out_extensions = ctx.attr.out_extensions

  # TODO(jakemac): Switch to bin_dir once that works as expected.
  out_base = ctx.configuration.genfiles_dir

  outs = _declare_outs(ctx, in_extension, out_extensions)
  if not outs:
    return

  log_path = "%s/%s/%s.log" % (out_base.path, ctx.label.package, ctx.label.name)
  if ctx.outputs.log_out_breaks_caching:
    log_path = ctx.outputs.log_out_breaks_caching.path
    outs += [ctx.outputs.log_out_breaks_caching]

  srcs_file = _inputs_tmp_file(ctx, ctx.files.srcs, "srcs_file")

  # Extra inputs required for the main action.
  extra_inputs = [srcs_file]

  arguments = [
      "--package-path=%s" % ctx.label.package,
      "--out=%s" % out_base.path,
      "--log=%s" % log_path,
      "--in-extension=%s" % in_extension,
      "--srcs-file=%s" % srcs_file.path,
  ]

  for ext in out_extensions:
    arguments.append("--out-extension=%s" % ext)

  arguments += ["--log-level=%s" % ctx.attr.log_level]
  # Prevent the code_gen ArgParser from interpreting generator args.
  arguments += ["--"]
  arguments += ctx.attr.generator_args

  if ctx.attr.omit_transitive_deps:
    filtered_deps = set([])
    for dep in ctx.attr.deps:
      for dep_file in dep.files:
        if dep.label.package in dep_file.path:
          filtered_deps += [dep_file]
  else:
    filtered_deps = ctx.files.deps

  if ctx.attr.deps_filter:
    deps_filter = ctx.attr.deps_filter
    filtered_deps = _filter_files(deps_filter, filtered_deps)
  filtered_deps += ctx.files.forced_deps

  # Worker-specific settings
  execution_requirements = {}
  if ctx.attr.supports_worker:
    # When running as a worker, we put all the args in a separate file.
    args_file = _args_file(ctx, arguments)
    extra_inputs.append(args_file)
    # Without this, the worker doesn't actually run.
    arguments = ["@%s" % args_file.path]
    # This is needed to signal bazel that the action actually supports running
    # as a worker.
    execution_requirements["supports-workers"] = "1"

  inputs = set([])
  inputs += ctx.files.srcs
  inputs += filtered_deps
  inputs += extra_inputs

  ctx.action(inputs=list(inputs),
             outputs=outs,
             executable=ctx.executable.generator,
             progress_message="Generating %s files %s " % (
                 ", ".join(out_extensions), ctx.label),
             mnemonic=_get_mnemonic(ctx),
             execution_requirements=execution_requirements,
             arguments=arguments)

  return struct(files=set(outs))

_dart_code_gen = rule(
    attrs = {
        "deps": attr.label_list(allow_files = True),
        "deps_filter": attr.string_list(),
        "forced_deps": attr.label_list(allow_files = True),
        "generator": attr.label(
            cfg = "host",
            executable = True,
        ),
        "generator_args": attr.string_list(),
        "in_extension": attr.string(default = ".dart"),
        "log_out_breaks_caching": attr.output(),
        "mnemonic": attr.string(),
        "omit_transitive_deps": attr.bool(default = False),
        "out_extensions": attr.string_list(mandatory = True),
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
        ),
        "supports_worker": attr.bool(default = False),
        "log_level": attr.string(default = "warning"),
    },
    output_to_genfiles = True,
    outputs = _compute_outs,
    implementation = _code_gen_impl,
)

def dart_code_gen(**kwargs):
  _dart_code_gen(log_level="warning", **kwargs)
