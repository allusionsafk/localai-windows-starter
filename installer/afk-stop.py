"""Uninstall-safe entry point for stopping AFK LocalAI.

This script is what the installed application runs for ``--stop``. It exists
because ``py -m localai stop`` is NOT safe here: ``localai`` is a single global
module name on a Python installation, so on a machine that also has the private
engineering workbench installed editable, that command runs the *workbench's*
code against the *workbench's* repository root.

So this script never trusts the ambient name. It loads the ``localai`` package
out of the payload sitting next to it, then *verifies* that is what it got
before doing anything. If it cannot prove it is running this installation's own
code, it stops nothing and exits 0 - an uninstall must not fail, and must never
guess about ownership.

Kept deliberately simple so it still parses and runs on an old interpreter: the
version gate has to be reachable before any modern syntax is evaluated.
"""

import os
import sys

MINIMUM_PYTHON = (3, 12)
REFUSAL = "Refusing to stop shared, unrelated, or unproven resources."


def _refuse(message):
    """Report why nothing was stopped, then succeed anyway."""
    sys.stderr.write("==== Stop AFK LocalAI ====\n")
    sys.stderr.write(message + "\n")
    sys.stderr.write(REFUSAL + "\n")
    return 0


def _parse_program_root(argv, default_root):
    for index, argument in enumerate(argv):
        if argument == "--program-root" and index + 1 < len(argv):
            return os.path.abspath(argv[index + 1])
        if argument.startswith("--program-root="):
            return os.path.abspath(argument.split("=", 1)[1])
    return default_root


def main(argv):
    if sys.version_info < MINIMUM_PYTHON:
        found = "%d.%d" % (sys.version_info[0], sys.version_info[1])
        return _refuse(
            "AFK LocalAI stop needs Python %d.%d or newer; found %s."
            % (MINIMUM_PYTHON[0], MINIMUM_PYTHON[1], found)
        )

    here = os.path.dirname(os.path.abspath(__file__))
    program_root = _parse_program_root(argv, os.path.dirname(here))
    source_root = os.path.join(program_root, "src")
    package_root = os.path.join(source_root, "localai")

    if not os.path.isdir(package_root):
        return _refuse(
            "No AFK LocalAI payload found at %s." % package_root
        )

    # Our own payload must win over any ambient install of the same name, and
    # anything already imported under that name must not be reused.
    sys.path.insert(0, source_root)
    for name in [
        module
        for module in list(sys.modules)
        if module == "localai" or module.startswith("localai.")
    ]:
        del sys.modules[name]

    try:
        import localai
    except ImportError as error:
        return _refuse("Could not load the AFK LocalAI payload: %s" % error)

    # Proof, not assumption: a .pth entry or a meta-path finder from another
    # installation could still have answered the import.
    resolved = os.path.abspath(getattr(localai, "__file__", "") or "")
    expected = os.path.join(package_root, "")
    if not resolved.lower().startswith(expected.lower()):
        return _refuse(
            "Resolved 'localai' from %s, which is not this installation (%s)."
            % (resolved or "<unknown>", package_root)
        )

    from localai.afk_ownership import collect_afk_stop_report

    code, lines = collect_afk_stop_report(program_root=program_root)
    for line in lines:
        sys.stdout.write(line + "\n")
    return code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
