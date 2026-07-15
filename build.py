import argparse
import platform
import shutil
import subprocess
import sys
import json
from pathlib import Path

# Config
EXE_NAME            = "run"         # name of the final executable (no extension)
BIN_DIR             = "bin"         # name of the final executable (no extension)
SRC_DIR             = "src"         # folder passed to `odin build`
THIRDPARTY_DIR      = "thirdparty"  # folder containing git-cloned libraries
SHADER_DIR          = "shaders"     # folder containing all shader files
EXTRA_BUILD_ARGS    = []            # any extra flags you always want, e.g. ["-vet"]
EXTRA_LINKER_FLAGS  = "-lstdc++"    # input to odin's "extra-linker-flags" build arg


PROJECT_DIR = Path(__file__).resolve().parent # Get the project root

parser = argparse.ArgumentParser(description="Odin project build script")
parser.add_argument("-d", "--debug",        action="store_true", help="build in debug mode")
parser.add_argument("-r", "--run",          action="store_true", help="run the executable after building")
parser.add_argument("--clean",              action="store_true", help="remove the built executable and exit")
parser.add_argument("--install-thirdparty", action="store_true", help="create thirdparty dependency directory and install dependencies")
parser.add_argument("--generate-ols-json",  action="store_true", help="generate ols.json file using the ")
args = parser.parse_args()

shader_path = PROJECT_DIR / SHADER_DIR
if not shader_path.exists():
    shader_path.mkdir()

bin_path = PROJECT_DIR / BIN_DIR
exe_path = bin_path / (EXE_NAME if platform.system() != "Windows" else EXE_NAME + ".exe")
if not bin_path.exists():
    bin_path.mkdir()

thirdparty_path = PROJECT_DIR / THIRDPARTY_DIR  # Add the THIRDPARTY_DIR to the project as a collection. This will let you
if not thirdparty_path.exists():                         # import packages in THIRDPARTY_DIR as: import "thirdparty:{package_name}"
    thirdparty_path.mkdir()

match platform.system():
    case "Windows":
        os_name = "windows"
    case "Linux":
        os_name = "linux"
    case _:
        os_name = "darwin"

# If cleaning, delete files and exit
if args.clean:
    for file in bin_path.iterdir():
        file.unlink()
        print(f"Removed {file}.")
    exit()

# Install third-party dependencies
if args.install_thirdparty:
    # TODO
    exit()

# Generate new ols.json
if args.generate_ols_json:
    ols_json = {
        "$schema": "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json",
        "enable_semantic_tokens": False,
        "enable_document_symbols": True,
        "enable_hover": True,
        "enable_snippets": True,
        "enable_auto_import": False,
        "profile": "default",
        "profiles": [ { "name": "default", "os": os_name, "checker_path": ["src"], "defines": { "ODIN_DEBUG": ("true" if args.debug else "false") } } ],
        "collections": [ { "name": "thirdparty", "path": str(thirdparty_path) } ]
    }
    with open(PROJECT_DIR / 'ols.json', 'w', encoding='utf-8') as file:
        json.dump(ols_json, file, indent=4)
    exit()

# Build the project
odin_path = shutil.which("odin")
if odin_path is None:
    sys.exit("error: could not find 'odin' in PATH.")

cmd = [
    odin_path,
    "build",
    str(PROJECT_DIR / SRC_DIR),
    f"-out:{exe_path}",
]
if not thirdparty_path.is_dir():
    exit("error: third-party dependency directory not found!")
cmd += [f"-collection:thirdparty={thirdparty_path}"]
if args.debug:
    cmd += ["-debug"]
else: # release mode
    cmd += ["-o:speed"]

# Define constants here
cmd += [f"-define:SHADER_DIR={shader_path}"]

# Extra linker flags
cmd += [f"-extra-linker-flags:{EXTRA_LINKER_FLAGS}"]

cmd += EXTRA_BUILD_ARGS

print(" ".join(cmd))
result = subprocess.run(cmd, cwd=PROJECT_DIR)
if result.returncode != 0:
    sys.exit(result.returncode)
print(f"Built {exe_path}")

# Run the code after building
if args.run:
    print(f"Running {exe_path}...\n")
    subprocess.run([str(exe_path)], cwd=PROJECT_DIR)

