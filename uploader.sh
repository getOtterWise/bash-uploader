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
    -type-coverage-file | --type-coverage-file)
        type_coverage_file="$2"
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
    -flag | --flag)
        flag="$2"
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
        echo "  --type-coverage-file = ${type_coverage_file}"
        echo "  --log-file = ${log_file}"
        echo "  --repo-token = ${repo_token}"
        echo "  --org-token = ${org_token}"
        echo "  --fail-on-errors = ${fail_on_errors}"
        echo "  --quiet = ${quiet}"
        echo "  --base-dir = ${base_dir}"
        echo "  --flag = ${flag}"
fi

########## VALIDATE REQUIRED TOOLS ##########
if test "${quiet:-0}" != "1"; then
    echo "Validating required tools..."
fi

missing_tools=()

if ! command -v git &> /dev/null; then
    missing_tools+=("git")
fi

if ! command -v curl &> /dev/null; then
    missing_tools+=("curl")
fi

if ! command -v jq &> /dev/null; then
    missing_tools+=("jq")
fi

if ! command -v awk &> /dev/null; then
    missing_tools+=("awk")
fi

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "ERROR: Missing required tools: ${missing_tools[*]}"
    echo "Please install the missing tools and try again."
    if test "${fail_on_errors:-0}" != "0"; then
        exit 1
    else
        exit 0
    fi
fi

if test "${quiet:-0}" != "1"; then
    echo "  All required tools found!"
fi

########## GIT ##########
if test "${quiet:-0}" != "1"; then
    echo "Attempting to detect Git info ..."
fi

branch_names="$(git branch 2>/dev/null)"
branch_name=""

if test "${quiet:-0}" != "1"; then
    echo "    git branch output: ${branch_names}"
fi

if [ -n "$branch_names" ]; then
    IFS=$'\n'
    read -r -a branches <<<"${branch_names}"

    for branch in "${branches[@]}"; do
        if [[ ${branch} = "* (no branch)" ]]; then
            branch_name="(no branch)"
        elif [[ ${branch} == *"* "* ]]; then
            branch_name=$(echo "${branch}" | sed -E 's|\* (\(HEAD detached at )?([\w\/\-\\]*)\)?|\2|' | sed -E 's|([\w\/\-\\]*)\)|\1|')
        fi
    done
fi

# If branch detection failed, try getting it from git symbolic-ref or rev-parse
if [ -z "$branch_name" ]; then
    branch_name=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi

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
    ci_repo="$(printenv TRAVIS_REPO_SLUG | xargs)"
    ci_head_commit="$(printenv TRAVIS_COMMIT | xargs)"

    # In PRs, TRAVIS_BRANCH is the target branch, TRAVIS_PULL_REQUEST_BRANCH is the source
    if [ "$ci_pr" != "false" ] && [ -n "$ci_pr" ]; then
        ci_branch="$(printenv TRAVIS_PULL_REQUEST_BRANCH | xargs)"
        ci_base_branch="$(printenv TRAVIS_BRANCH | xargs)"
    else
        ci_branch="$(printenv TRAVIS_BRANCH | xargs)"
    fi
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

    # Fallback for nektos/act or missing GITHUB_REPOSITORY
    if [[ -z "$ci_repo" ]] || [[ "$ci_repo" == *"/tmp/"* ]] || [[ "$ci_repo" == *"act-repo"* ]]; then
        if test "${quiet:-0}" != "1"; then
            echo "  GITHUB_REPOSITORY not set or invalid, detecting from git remote..."
        fi
        
        # Try to get repo from git remote URL
        git_remote_url=$(git config --get remote.origin.url 2>/dev/null || echo "")
        
        if [[ -n "$git_remote_url" ]]; then
            # Extract owner/repo from various git URL formats
            # SSH format: git@github.com:owner/repo.git
            # HTTPS format: https://github.com/owner/repo.git
            if [[ "$git_remote_url" =~ github\.com[:/]([^/]+/[^/]+)(\.git)?$ ]]; then
                ci_repo="${BASH_REMATCH[1]}"
                ci_repo="${ci_repo%.git}"  # Remove .git if present
                
                if test "${quiet:-0}" != "1"; then
                    echo "  Detected repo from git remote: ${ci_repo}"
                fi
            fi
        fi
    fi

    # consider usiing GITHUB_WORKSPACE for base_dir?

    github_ref="$(printenv GITHUB_REF | xargs)"
    github_event="$(printenv GITHUB_EVENT_NAME | xargs)"
    ci_head_commit="$(printenv GITHUB_SHA | xargs)"
    ci_author="$(printenv GITHUB_ACTOR | xargs)"

    if [[ ${github_event} = "pull_request" ]]; then
        if test "${quiet:-0}" != "1"; then
            echo "  Found Pull Request"
        fi
    
        if test "${quiet:-0}" != "1"; then
            echo "  Using GITHUB_EVENT_PATH for parsing Pull Request number"
        fi

        ci_pr=$(jq --raw-output .number "$GITHUB_EVENT_PATH")
        
        if [[ -z "$ci_pr" || ! "$ci_pr" =~ ^[0-9]+$ ]]; then
            if test "${quiet:-0}" != "1"; then
                echo "  Using refs for parsing Pull Request number"
            fi
            
            IFS='/'
            read -r -a refs <<<"${github_ref}"
            ci_pr="${refs[2]}"
        fi

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
    ci_branch="$(printenv CIRCLE_BRANCH | xargs)"
    ci_head_commit="$(printenv CIRCLE_SHA1 | xargs)"
    ci_author="$(printenv CIRCLE_USERNAME | xargs)"

    # Get repository from CIRCLE_PROJECT_USERNAME and CIRCLE_PROJECT_REPONAME
    circle_username="$(printenv CIRCLE_PROJECT_USERNAME | xargs)"
    circle_reponame="$(printenv CIRCLE_PROJECT_REPONAME | xargs)"
    if [ -n "$circle_username" ] && [ -n "$circle_reponame" ]; then
        ci_repo="${circle_username}/${circle_reponame}"
    fi
elif [ -n "$(printenv APPVEYOR | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected AppVeyor"
    fi
    ci_detected="appveyor"
    ci_pr="$(printenv APPVEYOR_PULL_REQUEST_NUMBER | xargs)"
    ci_branch="$(printenv APPVEYOR_REPO_BRANCH | xargs)"
    ci_job_id="$(printenv APPVEYOR_JOB_NUMBER | xargs)"
    ci_build_number="$(printenv APPVEYOR_BUILD_NUMBER | xargs)"
    ci_repo="$(printenv APPVEYOR_REPO_NAME | xargs)"
    ci_head_commit="$(printenv APPVEYOR_REPO_COMMIT | xargs)"
    ci_author="$(printenv APPVEYOR_REPO_COMMIT_AUTHOR | xargs)"
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
    ci_head_commit="$(printenv GIT_COMMIT | xargs)"
    ci_author="$(printenv CHANGE_AUTHOR | xargs)"

    # Try to extract repo from GIT_URL
    git_url="$(printenv GIT_URL | xargs)"
    if [ -n "$git_url" ]; then
        # Extract owner/repo from various git URL formats
        if [[ "$git_url" =~ github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$ ]]; then
            ci_repo="${BASH_REMATCH[1]}"
            ci_repo="${ci_repo%.git}"
        fi
    fi
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
    ci_repo=$(echo "$ci_clone_url" | sed -E 's|.*github\.com[:/]([^/]+/[^/]+)\.git|\1|')
    
    if test "${quiet:-0}" != "1"; then
        echo "  Found: ${ci_repo}"
    fi
elif [ -n "$(printenv GITLAB_CI | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected GitLab CI"
    fi
    ci_detected="gitlab-ci"
    ci_job_id="$(printenv CI_JOB_ID | xargs)"
    ci_build_number="$(printenv CI_PIPELINE_ID | xargs)"
    ci_pr="$(printenv CI_MERGE_REQUEST_IID | xargs)"
    ci_branch="$(printenv CI_COMMIT_BRANCH | xargs)"
    ci_base_branch="$(printenv CI_MERGE_REQUEST_TARGET_BRANCH_NAME | xargs)"
    ci_head_commit="$(printenv CI_COMMIT_SHA | xargs)"
    ci_author="$(printenv GITLAB_USER_LOGIN | xargs)"

    # Get repository from CI_PROJECT_PATH (format: owner/repo)
    ci_repo="$(printenv CI_PROJECT_PATH | xargs)"

    # For merge requests, use the source branch
    if [ -n "$ci_pr" ]; then
        ci_branch="$(printenv CI_MERGE_REQUEST_SOURCE_BRANCH_NAME | xargs)"
        ci_head_commit="$(printenv CI_MERGE_REQUEST_SOURCE_BRANCH_SHA | xargs)"
    fi
elif [ -n "$(printenv TF_BUILD | xargs)" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "  Detected Azure Pipelines"
    fi
    ci_detected="azure-pipelines"
    ci_job_id="$(printenv BUILD_BUILDID | xargs)"
    ci_build_number="$(printenv BUILD_BUILDNUMBER | xargs)"
    ci_branch="$(printenv BUILD_SOURCEBRANCHNAME | xargs)"
    ci_head_commit="$(printenv BUILD_SOURCEVERSION | xargs)"
    ci_author="$(printenv BUILD_REQUESTEDFOR | xargs)"

    # Get repository from BUILD_REPOSITORY_NAME (format: owner/repo)
    ci_repo="$(printenv BUILD_REPOSITORY_NAME | xargs)"

    # For pull requests
    if [ "$(printenv BUILD_REASON | xargs)" = "PullRequest" ]; then
        ci_pr="$(printenv SYSTEM_PULLREQUEST_PULLREQUESTNUMBER | xargs)"
        ci_branch="$(printenv SYSTEM_PULLREQUEST_SOURCEBRANCH | xargs)"
        ci_base_branch="$(printenv SYSTEM_PULLREQUEST_TARGETBRANCH | xargs)"

        # Clean up branch names (remove refs/heads/ prefix if present)
        ci_branch="${ci_branch#refs/heads/}"
        ci_base_branch="${ci_base_branch#refs/heads/}"
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

# todo teamcity
# todo herokuCI
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

# get comparison commit (base branch for PRs, parent commit for direct pushes)
# For PRs: compare against the base branch HEAD
# For direct pushes: compare against the parent commit
commit_parent=""

if [ -n "$ci_pr" ] && [ -n "$ci_base_branch" ]; then
    if test "${quiet:-0}" != "1"; then
        echo "    Detected PR, attempting to get base branch commit for: ${ci_base_branch}"
    fi

    # Try to resolve the base branch - first check if it exists locally
    base_branch_sha=$(git rev-parse --verify origin/${ci_base_branch} 2>/dev/null)

    if [ -z "$base_branch_sha" ]; then
        base_branch_sha=$(git rev-parse --verify ${ci_base_branch} 2>/dev/null)
    fi

    # If base branch not found locally, try fetching it (common in CI shallow clones)
    if [ -z "$base_branch_sha" ]; then
        if test "${quiet:-0}" != "1"; then
            echo "    Base branch not found locally, attempting to fetch: ${ci_base_branch}"
        fi

        git fetch origin ${ci_base_branch}:refs/remotes/origin/${ci_base_branch} --depth=1 2>/dev/null || true
        base_branch_sha=$(git rev-parse --verify origin/${ci_base_branch} 2>/dev/null)
    fi

    # Validate we got a valid commit SHA (40 hex characters)
    if [ -n "$base_branch_sha" ] && [[ "$base_branch_sha" =~ ^[0-9a-f]{40}$ ]]; then
        commit_parent="$base_branch_sha"

        if test "${quiet:-0}" != "1"; then
            echo "    Base Branch Commit: ${commit_parent}"
        fi
    else
        if test "${quiet:-0}" != "1"; then
            echo "    Could not resolve base branch, trying merge-base fallback"
        fi

        # Try to find merge base as fallback
        merge_base=$(git merge-base HEAD origin/${ci_base_branch} 2>/dev/null || git merge-base HEAD ${ci_base_branch} 2>/dev/null || echo "")

        if [ -n "$merge_base" ] && [[ "$merge_base" =~ ^[0-9a-f]{40}$ ]]; then
            commit_parent="$merge_base"

            if test "${quiet:-0}" != "1"; then
                echo "    Using merge-base: ${commit_parent}"
            fi
        fi
    fi
fi

# Fall back to direct parent commit if not in PR or base branch detection failed
if [ -z "$commit_parent" ]; then
    commit_parent=$(git rev-parse ${commit_sha}^1 2>/dev/null || echo "")

    if test "${quiet:-0}" != "1"; then
        echo "    Parent Commit: ${commit_parent:-<none>}"
    fi
fi

# get parent commit info if any
if test "${commit_parent}" != ""; then
    parent_commit_author_name=$(git log -1 --format="%an" "${commit_parent}" 2>/dev/null || echo "")
    parent_commit_author_email=$(git log -1 --format="%ae" "${commit_parent}" 2>/dev/null || echo "")
    parent_commit_message=$(git log -1 --format="%s" "${commit_parent}" 2>/dev/null || echo "<<NO PARENT>>")
    parent_commit_date=$(git log -1 --format="%at" "${commit_parent}" 2>/dev/null || echo "")
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

# Safely get diff, handling shallow clones and first commits
if [ -n "$commit_parent" ]; then
    diffContent=$(git diff ${commit_parent} ${commit_sha} --unified=0 2>/dev/null || echo "")
else
    # For first commit or when parent is not available, show all files as new
    if test "${quiet:-0}" != "1"; then
        echo "    No parent commit available, generating diff for first commit..."
    fi
    diffContent=$(git show --unified=0 --format="" ${commit_sha} 2>/dev/null || echo "")
fi

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
    elif [ -f "otterwise-coverage.xml" ]; then
        coverage_path="otterwise-coverage.xml"
    elif [ -f "build/logs/cobertura.xml" ]; then
        coverage_path="build/logs/cobertura.xml"
    elif [ -f "coverage/lcov.info" ]; then
        coverage_path="coverage/lcov.info"
    elif [ -f "coverage.out" ]; then
        coverage_path="coverage.out"
    elif [ -f "cobertura.xml" ]; then
        coverage_path="cobertura.xml"
    elif [ -f "clover.xml" ]; then
        coverage_path="clover.xml"
    elif [ -f "lcov.info" ]; then
        coverage_path="lcov.info"
    elif [ -f "coverage.xml" ]; then
        coverage_path="coverage.xml"
    elif [ -f "coverage.info" ]; then
        coverage_path="coverage.info"
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
if test "$log_file" == ""; then
    if test "${quiet:-0}" != "1"; then
        echo "Looking for log file ..."
    fi

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
    elif test "${quiet:-0}" != "1"; then
        echo "  Could not determine log file path, skipping"
    fi
else
    if [ ! -f "${log_file}" ]; then
        echo "Passed --file '${log_file}' does not exist."
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

if [[ -z "$repo_token" ]] && [[ -z "$org_token" ]]; then
    echo "ERROR: No repo_token or org_token provided. Need help? See https://getotterwise.com/docs/ci-providers/bash-uploader#repo-token"
    if test "${fail_on_errors:-0}" != "0"; then
        exit 1
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

# Clover, Cobertura or LCOV
if [[ "$coverage_path" == *.xml.otterwise ]]; then
    if grep -q "cobertura." "$coverage_path"; then
        # Cobertura
        awk -v base_dir="$base_dir_for_replacement" '/<method / { gsub(/name="[^"]*"/, "name=\"\"") }
                                   /<method / { gsub(/signature="[^"]*"/, "signature=\"\"") }
                                   /<source>/ { gsub(base_dir, "") } 1' "$coverage_path" > tmpfile && mv tmpfile "$coverage_path"
                                               
        if test "${quiet:-0}" != "1"; then
            echo "Stripped code and base directory from what was assumed to be a Cobertura Coverage File"
        fi
    elif grep -q "SF:" "$coverage_path" && grep -q "end_of_record" "$coverage_path"; then
        if test "${quiet:-0}" != "1"; then
            echo "File is LCOV, nothing to do here"
        fi
    else
        # Most likely Clover
        awk -v base_dir="$base_dir_for_replacement" '/<class / { gsub(/(name|namespace)="[^"]*"/, "") } /<line / { gsub(/(name|visibility)="[^"]*"/, "") } /<file / { gsub(base_dir, "") } 1' "$coverage_path" > tmpfile && mv tmpfile "$coverage_path"
        
        if test "${quiet:-0}" != "1"; then
            echo "Stripped code and base directory from what was assumed to be a Clover Coverage File"
        fi
    fi
fi



if test "${quiet:-0}" != "1"; then
    echo "Creating temporary file for git diff in _otterwise_diff_temp_.diff..."
fi

echo "$parsedDiff" > _otterwise_diff_temp_.diff


optionalArgs=()
if test "$log_file_path" != ""; then
    optionalArgs+=(-F log_file=@"${log_file_path}")
fi

if test "$config_path" != ""; then
    optionalArgs+=(-F config_file=@"${config_path}")
fi

if test "$mutation_file" != ""; then
    if test "${quiet:-0}" != "1"; then
        echo "Mutation file specified"
    fi

    # Ensure is Infection PHP format before stripping JSON
    if jq -e '.stats.totalMutantsCount' "${mutation_file}" > /dev/null 2>&1; then
        # Only do the code stripping and replacement step if has elements with code
        if jq -e '.escaped' "${mutation_file}" > /dev/null 2>&1; then
            if test "${quiet:-0}" != "1"; then
                echo "  Stripping code ..."
            fi
            # Remove code from Mutation log file (Infection)
            jq '(.escaped |= map(del(.mutator.mutatedSourceCode))) | (.timeouted |= map(del(.mutator.mutatedSourceCode))) | (.killed |= map(del(.mutator.mutatedSourceCode))) | (.errored |= map(del(.mutator.mutatedSourceCode))) | (.syntaxErrors |= map(del(.mutator.mutatedSourceCode))) | (.uncovered |= map(del(.mutator.mutatedSourceCode))) | (.ignored |= map(del(.mutator.mutatedSourceCode)))' "${mutation_file}" > "${mutation_file}.temp" && mv "${mutation_file}.temp" "${mutation_file}"
            jq '(.escaped |= map(del(.mutator.originalSourceCode))) | (.timeouted |= map(del(.mutator.originalSourceCode))) | (.killed |= map(del(.mutator.originalSourceCode))) | (.errored |= map(del(.mutator.originalSourceCode))) | (.syntaxErrors |= map(del(.mutator.originalSourceCode))) | (.uncovered |= map(del(.mutator.originalSourceCode))) | (.ignored |= map(del(.mutator.originalSourceCode)))' "${mutation_file}" > "${mutation_file}.temp" && mv "${mutation_file}.temp" "${mutation_file}"
            jq '.escaped |= map(del(.processOutput)) | .timeouted |= map(del(.processOutput)) | .killed |= map(del(.processOutput)) | .errored |= map(del(.processOutput)) | .syntaxErrors |= map(del(.processOutput)) | .uncovered |= map(del(.processOutput)) | .ignored |= map(del(.processOutput))' "${mutation_file}" > "${mutation_file}.temp" && mv "${mutation_file}.temp" "${mutation_file}"
            jq '.escaped |= map(del(.diff)) | .timeouted |= map(del(.diff)) | .killed |= map(del(.diff)) | .errored |= map(del(.diff)) | .syntaxErrors |= map(del(.diff)) | .uncovered |= map(del(.diff)) | .ignored |= map(del(.diff))' "${mutation_file}" > "${mutation_file}.temp" && mv "${mutation_file}.temp" "${mutation_file}"
        
            if test "${quiet:-0}" != "1"; then
                echo "  Replacing base_dir ..."
            fi
            
            # Remove base dir from Mutation log file (Infection)
            jq --arg homePath "$base_dir" '.escaped |= map(.mutator.originalFilePath |= sub($homePath; "")) | .timeouted |= map(.mutator.originalFilePath |= sub($homePath; "")) | .killed |= map(.mutator.originalFilePath |= sub($homePath; "")) | .errored |= map(.mutator.originalFilePath |= sub($homePath; "")) | .syntaxErrors |= map(.mutator.originalFilePath |= sub($homePath; "")) | .uncovered |= map(.mutator.originalFilePath |= sub($homePath; "")) | .ignored |= map(.mutator.originalFilePath |= sub($homePath; ""))' "${mutation_file}" > "${mutation_file}.temp" && mv "${mutation_file}.temp" "${mutation_file}"
        fi
        
        # Minify JSON
        if test "${quiet:-0}" != "1"; then
            echo "  Minifying JSON ..."
        fi
    
        cat ${mutation_file} | jq -c > "${mutation_file}.temp" && mv "${mutation_file}.temp" "${mutation_file}"
    fi

    # Add mutation file to upload
    optionalArgs+=(-F mutation_file=@"${mutation_file}")

    if test "${quiet:-0}" != "1"; then
        echo "  Prepared for upload!"
    fi
fi

if test "$type_coverage_file" != ""; then
    if test "${quiet:-0}" != "1"; then
        echo "Type Coverage file specified"
    fi

    # Ensure is Pest PHP format
    if jq -e '.format == "pest"' "${type_coverage_file}" > /dev/null 2>&1; then
        if test "${quiet:-0}" != "1"; then
            echo "  Format is Pest PHP"
            type_coverage_format="pest-php"
        fi
            
        # Add type coverage file to upload
        optionalArgs+=(-F type_coverage_file=@"${type_coverage_file}")
    fi
else
    # Attempt to locate Type Coverage files manually
    if [ -f "pest-type-coverage.json" ]; then
        if test "${quiet:-0}" != "1"; then
            echo "  Found pest-type-coverage.json, checking..."
        fi
        type_coverage_file="pest-type-coverage.json"
        
        # Ensure is Pest PHP format
        if jq -e '.format == "pest"' "${type_coverage_file}" > /dev/null 2>&1; then
            if test "${quiet:-0}" != "1"; then
                echo "  Format is Pest PHP"
                type_coverage_format="pest-php"
            fi
                
            # Add type coverage file to upload
            optionalArgs+=(-F type_coverage_file=@"${type_coverage_file}")
            optionalArgs+=(-F type_coverage_format="${type_coverage_format}")
        fi
    elif [ -f "build/logs/pest-type-coverage.json" ]; then
        if test "${quiet:-0}" != "1"; then
            echo "  Found build/logs/pest-type-coverage.json, checking..."
        fi
        type_coverage_file="build/logs/pest-type-coverage.json"
        
        # Ensure is Pest PHP format
        if jq -e '.format == "pest"' "${type_coverage_file}" > /dev/null 2>&1; then
            if test "${quiet:-0}" != "1"; then
                echo "  Format is Pest PHP"
                type_coverage_format="pest-php"
            fi
                
            # Add type coverage file to upload
            optionalArgs+=(-F type_coverage_file=@"${type_coverage_file}")
            optionalArgs+=(-F type_coverage_format="${type_coverage_format}")
        fi
    fi
fi

# Add flag
if test "$flag" != ""; then
    optionalArgs+=(-F flag="${flag}")
fi

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
    echo "  Log File: ${log_file_path}"
    echo "  Config File: ${config_path}"
    echo "  Type Coverage File: ${type_coverage_file}"
    echo "  Type Coverage Format: ${type_coverage_format}"
    echo "  Test Coverage File: ${coverage_path}"
    echo "  Mutation Coverage File: ${mutation_file}"
    echo "  Flag: ${flag}"
fi

if test "${quiet:-0}" != "1"; then
    echo "Uploading coverage ..."
fi

if ! UPLOAD_RESPONSE=$(curl --fail --connect-timeout 5 --retry 3 --retry-max-time 60 --retry-all-errors \
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
    -s "${endpoint:-https://otterwise.app/ingress/upload}"); then

    if test "${quiet:-0}" != "1"; then
        echo "Main upload endpoint failed after retries, using fallback endpoint"
    fi
    
    UPLOAD_RESPONSE=$(curl --fail --connect-timeout 5 --retry 3 --retry-max-time 60 --retry-all-errors \
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
        -s "https://otterwise.app/ingress/upload-fallback")
fi

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
