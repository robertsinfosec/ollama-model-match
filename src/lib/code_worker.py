"""Isolated code worker; expected answers remain exclusively in the parent."""

import contextlib
import copy
import json
import os

MAX_OUTPUT_BYTES = 1024**2


def type_shape(value):
    """Preserve Python container types across the JSON worker protocol."""
    if isinstance(value, list):
        return {"list": [type_shape(item) for item in value]}
    if isinstance(value, dict):
        return {"dict": {key: type_shape(item) for key, item in value.items()}}
    if type(value) in (int, float):
        return "number"
    return type(value).__name__


def main():
    # Import only in the Linux worker, so the protocol helper remains portable.
    import resource

    resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
    resource.setrlimit(resource.RLIMIT_AS, (256 * 1024**2, 256 * 1024**2))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_OUTPUT_BYTES, MAX_OUTPUT_BYTES))
    resource.setrlimit(resource.RLIMIT_NOFILE, (32, 32))
    resource.setrlimit(resource.RLIMIT_NPROC, (32, 32))

    with open("/work/spec.json") as source:
        spec = json.load(source)
    results = []
    namespace = {"__name__": "candidate"}
    try:
        with (
            open(os.devnull, "w") as quiet,
            contextlib.redirect_stdout(quiet),
            contextlib.redirect_stderr(quiet),
        ):
            with open("/work/candidate.py") as source:
                exec(compile(source.read(), "candidate.py", "exec"), namespace)
            for case in spec["cases"]:
                arguments = copy.deepcopy(case["args"])
                before = copy.deepcopy(arguments)
                try:
                    actual = namespace[spec["function"]](*arguments)
                    observed = {"actual": actual, "type_shape": type_shape(actual)}
                except BaseException as error:
                    observed = {"exception": type(error).__name__}
                observed["mutated"] = arguments != before
                results.append(observed)
        print(json.dumps({"results": results}))
    except BaseException as error:
        print(json.dumps({"error": type(error).__name__ + ": " + str(error)[:300]}))


if __name__ == "__main__":
    main()
