#!/bin/bash

# CI configuration
while [ $# -gt 0 ]; do
    case "$1" in
    -endpoint | --endpoint)
        endpoint="$2"
        ;;
    -file | --file)
        file="$2"
        ;;
    -mutation-file | --mutation-file)
        mutation_file="$2"
        ;;
    -log-file | --log-file)
        log_file="$2"
        ;;
    -quiet | --quiet)
        quiet=1
        ;;
    -repo-token | --repo-token)
        repo_token="$2"
        ;;
    -org-token | --org-token)
        org_token="$2"
        ;;
    -fail-on-errors | --stop-on-errors)
        fail_on_errors=1
        ;;
    -base-dir | --base-dir)
        base_dir="$2"
        ;;
    *) ;;
    esac
    shift
    shift
done

if test "${quiet:-0}" != "1"; then
        echo "Uploader Config:"
        echo "  --endpoint = ${endpoint}"
        echo "  --file = ${file}"
        echo "  --mutation-file = ${mutation_file}"
        echo "  --log-file = ${log_file}"
        echo "  --repo-token = ${repo_token}"
        echo "  --org-token = ${org_token}"
        echo "  --fail-on-errors = ${fail_on_errors}"
        echo "  --quiet = ${quiet}"
        echo "  --base-dir = ${base_dir}"
fi

########## GIT ##########
if test "${quiet:-0}" != "1"; then
    echo "Attempting to detect Git info ..."
fi

branch_names="$(git branch)"

if test "${quiet:-0}" != "1"; then
    echo "    git branch output: ${branch_names}"
fi

IFS=$'\n'
read -r -a branches <<<"${branch_names}"

for branch in "${branches[@]}"; do
    if [[ ${branch} = "* (no branch)" ]]; then
        branch_name="(no branch)"
    elif [[ ${branch} == *"* "* ]]; then
        branch_name=$(echo "${branch}" | sed -rE 's|\* (\(HEAD detached at )?([\w\/\-\\]*)\)?|\2|' | sed -rE 's|([\w\/\-\\]*)\)|\1|')
    fi
done

if test "${quiet:-0}" != "1"; then
    echo "    Branch: ${branch_name}"
fi

# Git Diff Wiper / Cleaner
parseGitDiff() {
    local diff="$1"
    IFS=$'\n' read -d '' -ra lines <<< "$diff"
    local linesOfGitDiffInfo=0

    for index in "${!lines[@]}"; do
        line="${lines[$index]}"

        if [[ $line == "diff --git a/"* ]]; then
            continue
        fi

        if [[ $line =~ ^(new file mode [0-9]{6}) ]]; then
            continue
        fi

        if [[ $line =~ ^(deleted file mode [0-9]{6}) ]]; then
            continue
        fi

        if [[ $line =~ ^(index ([0-9a-zA-Z]{7})\.\.([0-9a-zA-Z]{7})) ]]; then
            continue
        fi

        if [[ $line =~ ^(--- ) ]]; then
            continue
        fi

        if [[ $line =~ ^(\+\+\+ ) ]]; then
            continue
        fi

        if [[ $line =~ ^(@@ -[0-9]{1,}(,[0-9]{1,}){0,1} \+[0-9]{1,}(,[0-9]{1,}){0,1} @@) ]]; then
            lines[$index]="${BASH_REMATCH[1]}"
            continue
        fi

        lines[$index]="${line:0:1}"
    done

    printf "%s\n" "${lines[@]}"
}

########## CI ##########
if test "${quiet:-0}" != "1"; then
    echo "Attempting to detect CI environment ..."
fi
ci_pr=""
ci_repo=""
ci_branch=""
ci_base_branch=""
ci_head_commit=""
ci_author=""
if [ -n "$(printenv TRAVIS | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected TravisCI"
    fi
    ci_detected="travis-ci"
    ci_pr="$(printenv TRAVIS_PULL_REQUEST | xargs)"
    ci_job_id="$(printenv TRAVIS_JOB_ID | xargs)"
    ci_build_number="$(printenv TRAVIS_BUILD_NUMBER | xargs)"
elif [ -n "$(printenv GITHUB_ACTIONS | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected Github Actions"
    fi
    ci_detected="github-actions"
    ci_job_id="$(printenv GITHUB_RUN_ID | xargs)"
    ci_build_number="$(printenv GITHUB_RUN_NUMBER | xargs)"
    ci_base_branch="$(printenv GITHUB_BASE_REF | xargs)"
    ci_branch="$(printenv GITHUB_HEAD_REF | xargs)"
    ci_repo="$(printenv GITHUB_REPOSITORY | xargs)"

    # consider usiing GITHUB_WORKSPACE for base_dir?

    github_ref="$(printenv GITHUB_REF | xargs)"
    github_event="$(printenv GITHUB_EVENT_NAME | xargs)"
    ci_head_commit="$(printenv GITHUB_SHA | xargs)"
    if [[ ${github_event} = "pull_request" ]]; then
        if test "${quiet:-0}" != "1"; then
            echo "  Found Pull Request"
        fi
        IFS='/'
        read -r -a refs <<<"${github_ref}"
        ci_pr="${refs[2]}"

        merge_message="$(git show --no-patch --format=%P | xargs)"

        if [[ "${merge_message}" == *" "* ]]; then
            IFS=' '
            read -r -a merge_message <<<"${merge_message}"
            ci_head_commit="${merge_message[1]}"
        fi
    fi
elif [ -n "$(printenv CIRCLECI | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected CircleCI"
    fi
    ci_detected="circle-ci"
    ci_job_id="$(printenv CIRCLE_WORKFLOW_ID | xargs)"
    ci_build_number="$(printenv CIRCLE_WORKFLOW_ID | xargs)"
    ci_pr="$(printenv CIRCLE_PR_NUMBER | xargs)"
elif [ -n "$(printenv APPVEYOR | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected AppVeyer"
    fi
    ci_detected="appveyor"
    ci_pr="$(printenv APPVEYOR_PULL_REQUEST_NUMBER | xargs)"
    ci_branch="$(printenv APPVEYOR_REPO_BRANCH | xargs)"
    ci_job_id="$(printenv APPVEYOR_JOB_NUMBER | xargs)"
    ci_build_number="$(printenv APPVEYOR_BUILD_NUMBER | xargs)"
elif [ -n "$(printenv JENKINS_URL | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected Jenkins"
    fi
    ci_detected="jenkins"
    ci_pr="$(printenv ghprbPullId | xargs)"
    ci_build_number="$(printenv BUILD_NUMBER | xargs)"
    ci_pr="${ci_pr:=$(printenv CHANGE_ID | xargs)}"
    ci_branch="$(printenv ghprbSourceBranch | xargs)"
    ci_branch="${ci_branch:=$(printenv CHANGE_BRANCH | xargs)}"
    ci_branch="${ci_branch:=$(printenv GIT_BRANCH | xargs)}"
    ci_branch="${ci_branch:=$(printenv BRANCH_NAME | xargs)}"
elif [ -n "$(printenv CHIPPER | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected ChipperCI"
        echo "  Environment:"
     
        echo "    CI_COMMIT_SHA: $(printenv CI_COMMIT_SHA | xargs)"
        echo "    CI_COMMIT_SHA_SHORT: $(printenv CI_COMMIT_SHA_SHORT | xargs)"
        echo "    CI_COMMIT_BRANCH: $(printenv CI_COMMIT_BRANCH | xargs)"
        echo "    CI_COMMIT_TAG: $(printenv CI_COMMIT_TAG | xargs)"
        echo "    CI_COMMIT_MESSAGE: $(printenv CI_COMMIT_MESSAGE | xargs)"
        echo "    CI_CLONE_URL: $(printenv CI_CLONE_URL | xargs)"
        echo "    CI_COMMIT_USER: $(printenv CI_COMMIT_USER | xargs)"
    fi
    
    ci_detected="chipper-ci"
    ci_pr="$(printenv CI_COMMIT_TAG | xargs)" # todo figure out if this is correct (is it release, not PR?)
    ci_branch="$(printenv CI_COMMIT_BRANCH | xargs)"
    ci_clone_url="$(printenv CI_CLONE_URL | xargs)"
    ci_author="$(printenv CI_COMMIT_USER | xargs)"
    
    if test "${quiet:-0}" != "1"; then
        echo "  Using Clone URL to detect repository: ${ci_clone_url}"
    fi
    
    # Try with GitHub format
    ci_repo=$(echo "$ci_clone_url" | sed -rE 's|.*github\.com[:/]?([^/]+/[^/]+)\.git|\1|')
    
    if test "${quiet:-0}" != "1"; then
        echo "  Found: ${ci_repo}"
    fi
elif [ -n "$(printenv COTTER_LOCAL | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected Local"
    fi
    ci_detected="local"
else
    if test "${quiet:-0}" != "1"; then
        echo "  Could not detect CI"

        if test "${fail_on_errors:-0}" != "0"; then
            exit 1
        else
            exit 0
        fi
    fi
fi

# todo gitlabCI
# todo teamcity
# todo herokuCI
# todo azurePipelines
# todo bitbucketCI


########## GIT INFO ##########


# get commit sha from either CI info or git log
commit_sha=${ci_head_commit:-$(git log -1 --pretty=format:'%H' | xargs)}

if test "${quiet:-0}" != "1"; then
    echo "    Commit SHA: ${commit_sha}"
fi

# get commit info
head_commit_author_name=$(git log -1 --format="%an" ${commit_sha})
head_commit_author_email=$(git log -1 --format="%ae" ${commit_sha})
head_commit_message=$(git log -1 --format="%s" ${commit_sha})
head_commit_date=$(git log -1 --format="%at" ${commit_sha})

if test "${quiet:-0}" != "1"; then
    echo "    Commit Author: ${head_commit_author_name} <${head_commit_author_email}>"
    echo "    Commit Message: ${head_commit_message}"
    echo "    Commit Date: ${head_commit_date}"
fi

# get first parent commit
commit_parent=$(git rev-parse $(git log -1 --pretty=format:'%H' | xargs)^1)

if test "${quiet:-0}" != "1"; then
    echo "    Commit Parent: ${commit_parent}"
fi

# get parent commit info if any
if test "${commit_parent}" != ""; then
    parent_commit_author_name=$(git log -1 --format="%an" ${commit_parent})
    parent_commit_author_email=$(git log -1 --format="%ae" ${commit_parent})
    parent_commit_message=$(git log -1 --format="%s" ${commit_parent})
    parent_commit_date=$(git log -1 --format="%at" ${commit_parent})
else
    parent_commit_author_name=""
    parent_commit_author_email=""
    parent_commit_message="<<NO PARENT>>"
    parent_commit_date=""
fi

if test "${quiet:-0}" != "1"; then
    echo "    Parent Commit Author: ${parent_commit_author_name} <${parent_commit_author_email}>"
    echo "    Parent Commit Message: ${parent_commit_message}"
    echo "    Parent Commit Date: ${parent_commit_date}"
fi



########## GIT DIFF ##########
if test "${quiet:-0}" != "1"; then
    echo "Retrieving Git Diff ..."
fi

diffContent=$(git diff HEAD^1 HEAD --unified=0)

if test "${quiet:-0}" != "1"; then
    echo "    Wiping code from Git Diff ..."
fi

parsedDiff=$(parseGitDiff "$diffContent")

if test "${quiet:-0}" != "1"; then
    echo "    Git Diff retrieved and wiped!"
fi

########## COVERAGE FILE ##########
if test "${quiet:-0}" != "1"; then
    echo "Looking for coverage file ..."
fi
if test "$file" == ""; then
    if [ -f "build/logs/clover.xml" ]; then
        coverage_path="build/logs/clover.xml"
    elif [ -f "build/logs/cobertura.xml" ]; then
        coverage_path="build/logs/cobertura.xml"
    else
        echo "  Could not determine Coverage file path, please verify that the file exists. Alternatively pass it with --file [PATH]"
        if test "${fail_on_errors:-0}" != "0"; then
            exit 1
        else
            exit 0
        fi
    fi
else
    if [ ! -f "${file}" ]; then
        echo "  Passed --file '${file}' does not exist."
        if test "${fail_on_errors:-0}" != "0"; then
            exit 1
        else
            exit 0
        fi
    fi
    coverage_path="${file}"
fi

if test "${quiet:-0}" != "1"; then
    echo "  Found at ${coverage_path}"
fi

########## CONFIG FILE ##########
 if [ -f ".otterwise.yml" ]; then
    config_path=".otterwise.yml"
        
    if test "${quiet:-0}" != "1"; then
        echo "Found config file, will be used for overwriting repository and organization settings."
    fi
else
    if test "${quiet:-0}" != "1"; then
        echo "No config file found, using repository and organization settings."
    fi
fi

########## LOG FILE ##########
# todo strip base dir!
if test "${quiet:-0}" != "1"; then
    echo "Looking for log file ..."
fi
if test "$log_file" == ""; then
    if [ -f "build/logs/junit-log.xml" ]; then
        log_file_path="build/logs/junit-log.xml"

        if test "${quiet:-0}" != "1"; then
            echo "  Found at ${log_file_path}"
        fi
    elif [ -f "phpunit/junit.xml" ]; then
        log_file_path="phpunit/junit.xml"

        if test "${quiet:-0}" != "1"; then
            echo "  Found at ${log_file_path}"
        fi
    elif [ -f "build/logs/junit.xml" ]; then
        log_file_path="build/logs/junit.xml"

        if test "${quiet:-0}" != "1"; then
            echo "  Found at ${log_file_path}"
        fi
    else
        echo "  Could not determine log file path, skipping"
    fi
else
    if [ ! -f "${log_file}" ]; then
        echo "  Passed --file '${log_file}' does not exist."
    fi
    log_file_path="${log_file}"
fi

########## INFO ##########
if test "$base_dir" == ""; then
    if test "${quiet:-0}" != "1"; then
        echo "No --base-dir set, getting from pwd"
    fi

    base_dir="$(pwd)"

    if test "${quiet:-0}" != "1"; then
        echo "  Set to: ${base_dir}"
    fi
fi

if [[ -z "${repo_token}" ]]; then
    if test "${quiet:-0}" != "1"; then
        echo "No --repo-token set, getting from OTTERWISE_TOKEN environment variable"
    fi

    repo_token=$(printenv OTTERWISE_TOKEN | xargs)

    if test "${quiet:-0}" != "1"; then
        echo "  Found: ${repo_token}"
    fi
fi


if [[ -z "${org_token}" ]]; then
    if test "${quiet:-0}" != "1"; then
        echo "No --org-token set, getting from OTTERWISE_ORG_TOKEN environment variable"
    fi

    org_token=$(printenv OTTERWISE_ORG_TOKEN | xargs)

    if test "${quiet:-0}" != "1"; then
        echo "  Found: ${org_token}"
    fi
fi

########## Make a copy of the coverage file ##########
cp "${coverage_path}" "$coverage_path.otterwise"
            
if test "${quiet:-0}" != "1"; then
    echo "Created copy of coverage file"
fi

# Switch to using the copy instead
coverage_path="$coverage_path.otterwise"

if test "${quiet:-0}" != "1"; then
    echo "Switching coverage path to: ${coverage_path}"
fi

########## STRIP CODE FROM COVERAGE ##########
if [[ "${base_dir: -1}" != "/" ]]; then
    base_dir_for_replacement="${base_dir}/"
else
    base_dir_for_replacement="${base_dir}"
fi

# Clover or Cobertura
if [[ "$coverage_path" == *.xml.otterwise ]]; then
    if grep -q "cobertura." "$coverage_path"; then
            # Cobertura
            awk -v base_dir="$base_dir_for_replacement" '/<package / { gsub(/name="[^"]*"/, "name=\"\"") }
                                       /<class / { gsub(/name="[^"]*"/, "name=\"\"") }
                                       /<method / { gsub(/name="[^"]*"/, "name=\"\"") }
                                       /<source>/ { gsub(base_dir, "") } 1' "$input_file" > tmpfile && mv tmpfile "$input_file"
                                                   
            if test "${quiet:-0}" != "1"; then
                echo "Stripped code and base directory from what was assumed to be a Cobertura Coverage File"
            fi
    else
            # Most likely Clover
            awk -v base_dir="$base_dir_for_replacement" '/<class / { gsub(/(name|namespace)="[^"]*"/, "") } /<line / { gsub(/(name|visibility)="[^"]*"/, "") } /<file / { gsub(base_dir, "") } 1' "$coverage_path" > tmpfile && mv tmpfile "$coverage_path"
            
            if test "${quiet:-0}" != "1"; then
                echo "Stripped code and base directory from what was assumed to be a Clover Coverage File"
            fi
    fi
fi

# todo clean stuff we dont need
if test "${quiet:-0}" != "1"; then
    echo "Detected data:"
    echo "  Git Branch: ${branch_name}"
    echo "  Git Commit Sha: ${commit_sha}"
    echo "  Git Commit Author: ${head_commit_author_name} (${head_commit_author_email})"
    echo "  Git Commit Message: ${head_commit_message}"
    echo "  Git Parent Commit Sha: ${commit_parent}"
    echo "  Git Parent Commit Author: ${parent_commit_author_name} (${parent_commit_author_email})"    
    echo "  Git Parent Commit Message: ${parent_commit_message}"
    echo "  CI Provider: ${ci_detected}"
    echo "  CI JOB: ${ci_job_id}"
    echo "  CI Build: ${ci_build_number}"
    echo "  CI PR: ${ci_pr}"
    echo "  CI Head Commit: ${ci_head_commit}"
    echo "  CI Head Branch: ${ci_branch}"
    echo "  CI Base Branch: ${ci_base_branch}"
    echo "  CI Repo: ${ci_repo}"
    echo "  CI Author: ${ci_author}"
    echo "  Base Dir: ${base_dir}"
    echo "  Endpoint: ${endpoint:-https://otterwise.app/ingress/upload}"
fi

if test "${quiet:-0}" != "1"; then
    echo "Creating temporary file for git diff in _otterwise_diff_temp_.diff..."
fi

echo "$parsedDiff" > _otterwise_diff_temp_.diff


if test "${quiet:-0}" != "1"; then
    echo "Uploading coverage ..."
fi

optionalArgs=()
if test "$log_file_path" != ""; then
    optionalArgs+=(-F log_file=@"${log_file_path}")
fi

if test "$config_path" != ""; then
    optionalArgs+=(-F config_file=@"${config_path}")
fi

if test "$mutation_file" != ""; then
    optionalArgs+=(-F mutation_file=@"${mutation_file}")
fi

UPLOAD_RESPONSE=$(curl --connect-timeout 5 --retry 3 --retry-max-time 60 --retry-all-errors \
    -F clover=@"${coverage_path}" \
    -F diff=@"_otterwise_diff_temp_.diff" \
    -F ci_provider="${ci_detected}" \
    -F ci_job="${ci_job_id}" \
    -F ci_build="${ci_build_number}" \
    -F ci_author="${ci_author}" \
    -F repo_token="${repo_token}" \
    -F org_token="${org_token}" \
    -F git_repo="${ci_repo}" \
    -F git_pr="${ci_pr}" \
    -F git_head_commit="${ci_head_commit:-$commit_sha}" \
    -F git_base_branch="${ci_base_branch}" \
    -F git_head_branch="${ci_branch}" \
    -F git_branch="${branch_name}" \
    -F head_commit_author_name="${head_commit_author_name}" \
    -F head_commit_author_email="${head_commit_author_email}" \
    -F head_commit_author_message="${head_commit_message}" \
    -F head_commit_author_date="${head_commit_date}" \
    -F parent_commit_sha="${commit_parent}" \
    -F parent_commit_author_name="${parent_commit_author_name}" \
    -F parent_commit_author_email="${parent_commit_author_email}" \
    -F parent_commit_author_message="${parent_commit_message}" \
    -F parent_commit_author_date="${parent_commit_date}" \
    -F base_dir="${base_dir}" \
    "${optionalArgs[@]}" \
    -s "${endpoint:-https://otterwise.app/ingress/upload}")

uploaded=$(grep -o 'Queued for processing' <<< "${UPLOAD_RESPONSE}")

if test "${quiet:-0}" != "1"; then
    echo "Deleting temporary git diff file from _otterwise_diff_temp_.diff..."
fi

rm _otterwise_diff_temp_.diff

echo "$parsedDiff" > _otterwise_diff_temp_.diff

if test "${uploaded}" == "Queued for processing"; then
    echo "  Coverage uploaded to OtterWise for processing!"
else
    echo "  Upload of code coverage to OtterWise failed with response: ${UPLOAD_RESPONSE}"

    if test "${fail_on_errors:-0}" != "0"; then
        exit 1
    fi
fi
