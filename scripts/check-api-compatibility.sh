#!/bin/bash
# Check API compatibility of all packages
set -eu

repo_root="$(cd $(dirname $0)/.. && pwd)"
tmpdir=/tmp/compat-check

package_name() {
    node -pe "require('$1/package.json').name"
}

# Determine whether an NPM package exists on NPM
#
# Doesn't use 'npm view' as that is slow. Direct curl'ing npmjs is better
package_exists_on_npm() {
    pkg=$1
    ver=$2 # optional
    curl -I 2>/dev/null https://registry.npmjs.org/$pkg/$ver | head -n 1 | grep 200 >/dev/null
}


#----------------------------------------------------------------------

list_jsii_packages() {
    echo "Listing jsii packages..." >&2
    for dir in $(npx lerna ls -p); do
        if [[ -f $dir/.jsii ]]; then
            echo "$dir"
        fi
    done
}
jsii_package_dirs=$(list_jsii_packages)

#----------------------------------------------------------------------

# Input a directory, output the package name IF it exists on GitHub
dirs_to_existing_names() {
    local dir="$1"
    local name=$(package_name "$dir")
    if package_exists_on_npm $name; then
        echo "$name"
        echo -n "." >&2
    else
        echo -n "x" >&2
    fi
}

export -f package_name
export -f package_exists_on_npm
export -f dirs_to_existing_names

if ! ${SKIP_DOWNLOAD:-false}; then
    echo "Filtering on existing packages on NPM..." >&2
    # In parallel
    existing_names=$(echo "$jsii_package_dirs" | xargs -n1 -P4 -I {} bash -c 'dirs_to_existing_names "$@"' _ {})
    echo " Done." >&2

    current_version=$(node -p 'require("./lerna.json").version')
    echo "Current version in lerna.json is $current_version"
    if ! ${DOWNLOAD_LATEST:-false} && package_exists_on_npm aws-cdk $current_version; then
        echo "Using package version ${current_version} as baseline"
        existing_names=$(echo "$existing_names" | sed -e "s/$/@$current_version/")
    else
        echo "However, using the latest version from NPM as the baseline"
    fi

    rm -rf $tmpdir
    mkdir -p $tmpdir

    echo "Installing from NPM..." >&2
    (cd $tmpdir && npm install --prefix $tmpdir $existing_names)
fi

#----------------------------------------------------------------------

echo "Checking compatibility..." >&2
success=true
for dir in $jsii_package_dirs; do
    name=$(package_name "$dir")
    if [[ ! -d $tmpdir/node_modules/$name ]]; then continue; fi
    if [[ ! -f $tmpdir/node_modules/$name/.jsii ]]; then continue; fi
    echo -n "$name... "
    if npx jsii-diff \
        --keys \
        --ignore-file ${repo_root}/allowed-breaking-changes.txt \
        $tmpdir/node_modules/$name \
        $dir \
        2>$tmpdir/output.txt; then
        echo "OK."
    else
        success=false
        echo "CHANGES."
        cat $tmpdir/output.txt
    fi
done

if $success; then
    echo "All OK." >&2
else
    echo "Some packages seem to have undergone breaking API changes. Please avoid." >&2

    exit 1
fi
