#!/bin/bash

set -o errexit
# Conda does not like 'set -o nounset'

echo "#####################################################"
echo "# This script installs mirgecom, and dependencies.  #"
echo "#####################################################"
echo

# We need an MPI installation to build mpi4py.
# Check that one is available.
if ! command -v mpicc &> /dev/null ;then
    echo "=== Error: You need an MPI installation for mirgecom."
    exit 2
fi


if [[ $(hostname) == tioga* || $(hostname) == odyssey || $(hostname) == tuolumne* ]]; then
  if [[ -z $ROCM_PATH ]]; then
    # ROCM_PATH is needed below to install the AMD OpenCL ICD link
    echo "**** Error: No ROCM_PATH environment variable set."
    echo "**** Please load the appropriate 'rocm' module."
    exit 3
  else
    echo "==== Using system ROCM at $ROCM_PATH"
  fi
fi

usage()
{
  echo "Usage: $0 [--install-prefix=DIR] [--branch=NAME] [--conda-prefix=DIR]"
  echo "                   [--env-name=NAME] [--modules] [--help]"
  echo "  --install-prefix=DIR  Install mirgecom in [DIR], (default=PWD)."
  echo "  --conda-prefix=DIR    Install conda in [DIR], (default=./miniforge3)"
  echo "  --env-name=NAME       Name of the conda environment to install to. (default=ceesd)"
  echo "  --modules             Create modules.zip and add to Python path."
  echo "  --branch=NAME         Install specific branch of mirgecom (default=main)."
  echo "  --fork=NAME           Install mirgecom from a fork (default=illinois-ceesd)"
  echo "  --conda-pkgs=FILE     Install these additional packages with conda."
  echo "  --conda-env=FILE      Obtain conda package versions from conda environment file FILE."
  echo "  --pip-pkgs=FILE       Install these additional packages with pip."
  echo "  --py-ver=VERSION      Replace the Python version specified in the conda environment file with VERSION (e.g., --py-ver=3.10)."
  echo "  --git-ssh             Use SSH-based URL to clone mirgecom."
  echo "  --debug               Show debugging output of this script (set -x)."
  echo "  --skip-clone          Skip cloning mirgecom, assume it will be manually copied."
  echo "  --help                Print this help text."
}

mcbranch="main"
mcfork="astro-friedel"
mcprefix=$(pwd)
# {{{ Default conda location

# https://stackoverflow.com/q/39340169
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
conda_prefix=$SCRIPT_DIR/miniforge3
env_name="ceesd"
pip_pkg_file=""
conda_pkg_file=""
conda_env_file=""

# }}}

# Build modules.zip? (via makezip.sh)
opt_modules=0

# Switch mirgecom to use ssh URL
opt_git_ssh=0

# Skip cloning mirgecom
opt_skip_clone=0

opt_py_ver=

while [[ $# -gt 0 ]]; do
  arg=$1
  shift
  case $arg in
    --install-prefix=*)
        # Install mirgecom in non-default prefix
        mcprefix=${arg#*=}
        mcprefix=${mcprefix//\~/$HOME} # Conda does not like ~
        ;;
    --conda-prefix=*)
        # Install conda in non-default prefix
        conda_prefix=${arg#*=}
        conda_prefix=${conda_prefix//\~/$HOME} # Conda does not like ~
        ;;
    --env-name=*)
        # Use non-default environment name
        env_name=${arg#*=}
        ;;
    --branch=*)
        # Install specified branch of mirgecom
        mcbranch=${arg#*=}
        ;;
    --fork=*)
        # Install mirgecom from specified fork
        mcfork=${arg#*=}
        ;;
    --conda-pkgs=*)
        # Install these additional packages with conda
        conda_pkg_file=${arg#*=}
        ;;
    --conda-env=*)
        # Install this conda environment instead of the one created by the emirge scripts
        conda_env_file=${arg#*=}
        ;;
    --pip-pkgs=*)
        # Install these additional packages with pip
        pip_pkg_file=${arg#*=}
        ;;
    --modules)
        # Create modules.zip
        opt_modules=1
        ;;
    --git-ssh)
        opt_git_ssh=1
        ;;
    --debug)
        set -x
        ;;
    --skip-clone)
        opt_skip_clone=1
        ;;
    --py-ver=*)
        # Install this python version instead of the version specified in the conda env file.
        opt_py_ver=${arg#*=}
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        echo "=== Error: unknown argument '$arg' ."
        usage
        exit 1
        ;;
  esac
done


export MY_CONDA_DIR=$conda_prefix

echo "==== Conda installation"

./install-conda.sh

# Make sure we get the just installed conda.
# See https://github.com/conda/conda/issues/10133 for details.
#shellcheck disable=SC1091
source "$MY_CONDA_DIR"/bin/activate

export PATH=$MY_CONDA_DIR/bin:$PATH

echo "==== Fetching mirgecom"

mkdir -p "$mcprefix"
mcsrc="$mcprefix/mirgecom"

if [[ $opt_skip_clone -eq 0 ]]; then
  if [[ -f "$mcsrc/setup.py" ]]; then
    # mirgecom src already populated, checkout the right branch, pull it
    (cd "$mcsrc" && git checkout "$mcbranch" && git pull)
  else
    # clone specific branch to mirgecom src
    if [[ $opt_git_ssh -eq 0 ]]; then
      (cd "$mcprefix" && git clone --branch "$mcbranch" https://github.com/"$mcfork"/mirgecom)
    else
      (cd "$mcprefix" && git clone --branch "$mcbranch" git@github.com:"$mcfork"/mirgecom)
    fi
  fi
fi

echo "==== Create $env_name conda environment"

[[ -z $conda_env_file ]] && conda_env_file="$mcsrc/conda-env.yml"

# Make a copy of the file since we might modify it
cp "$conda_env_file" "$conda_env_file".yml
conda_env_file=$conda_env_file.yml

if [[ -n $opt_py_ver ]]; then
  echo "=== Overriding Python version with $opt_py_ver"
  sed -i.bak "s,- python=3[0-9\.]*,- python=$opt_py_ver," "$conda_env_file"
fi

# Due to https://github.com/conda/conda/issues/8089, we have to install these
# packages manually on specific operating systems:
# Required to use pocl on macOS Big Sur+:
# https://github.com/illinois-ceesd/emirge/issues/114
# https://github.com/conda-forge/pocl-feedstock/pull/96
if [[ $(uname) == "Darwin" ]]; then
  echo "=== adding clang_osx and ld64 to conda environment file"
  echo "- ld64=609" >> "$conda_env_file"
  [[ $(uname -m) == "x86_64" ]] && echo "- clang_osx-64" >> "$conda_env_file"
  [[ $(uname -m) == "arm64" ]] &&  echo "- clang_osx-arm64" >> "$conda_env_file"
fi

cat "$conda_env_file"

mamba env create --name "$env_name" --yes --file="$conda_env_file"

# Avoid a 'frankenconda' env that uses Python from the base env.
# See https://github.com/illinois-ceesd/emirge/pull/132 for details.
# Srtike 1: deactivate the non-functional env:
conda deactivate
# Strike 2: deactivate conda base env:
conda deactivate
# Strike 3: activate the desired env, which now actually works:
#shellcheck disable=SC1091
source "$MY_CONDA_DIR"/bin/activate "$env_name"

if [[ -n "$conda_pkg_file" ]]; then
  echo "==== Installing custom packages from file ($conda_pkg_file)."
  # shellcheck disable=SC2013
  for package in $(cat "$conda_pkg_file"); do
    echo "=== Installing user-custom package ($package)."
    mamba install --yes "$package"
  done
fi

# shellcheck disable=SC2153
echo "==== Creating pin file for conda packages: $CONDA_PREFIX/conda-meta/pinned"
echo 'pocl=5.0=*_6' > "$CONDA_PREFIX"/conda-meta/pinned

if [[ $(uname) == "Darwin" ]]; then
  echo 'ld64=609' >> "$CONDA_PREFIX"/conda-meta/pinned
fi


if [[ $(hostname) == tioga* || $(hostname) == odyssey || $(hostname) == tuolumne* ]]; then
  echo "**** Installing AMD OpenCL ICD (rocm) for Tioga/Odyssey/Tuolumne"
  #shellcheck disable=SC2153
  echo "$ROCM_PATH/lib/libamdocl64.so" > "$CONDA_PREFIX/etc/OpenCL/vendors/amd_ceesd.icd"
fi

# Install an environment activation script
rm -rf "$mcprefix"/config
mkdir -p "$mcprefix"/config
cat << EOF > "$mcprefix"/config/activate_env.sh
#!/bin/bash
#
# Automatically generated by emirge install
#

# Make sure we get this conda, not another (e.g. system) conda.
# See https://github.com/conda/conda/issues/10133 and
# https://github.com/illinois-ceesd/emirge/issues/101 for context.
if [[ ":\$PATH:" != *":$MY_CONDA_DIR/bin:"* ]]; then
    export PATH=$MY_CONDA_DIR/bin:\$PATH
fi

echo "Activating '$env_name' environment for '\$(which conda)'."

source $MY_CONDA_DIR/bin/activate $env_name

EOF
chmod +x "$mcprefix"/config/activate_env.sh

echo "==== Installing pip packages"

./install-pip-dependencies.sh "$mcsrc/requirements.txt" "$mcprefix"
if [[ -n "$pip_pkg_file" ]]; then
    ./install-pip-dependencies.sh "$pip_pkg_file" "$mcprefix"
fi
./install-src-package.sh "$mcsrc" "develop"

[[ $opt_modules -eq 1 ]] && ./makezip.sh

# Remove the temporary conda environment file
rm -f "$conda_env_file"

echo
echo "==================================================================="
echo "Mirgecom is now installed in $mcsrc."
echo "Before using this installation, one should load the appropriate"
echo "conda environment (assuming bash shell):"
echo " $ source $mcprefix/config/activate_env.sh"
echo "To test the installation:"
echo " $ cd $mcsrc/test && pytest *.py"
echo "To run the examples:"
echo " $ cd $mcsrc/examples && ./run_examples.sh ./"
echo "==================================================================="
