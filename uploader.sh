#!/bin/bash
# CONFIG
while [ $# -gt 0 ]; do
    case "$1" in
    -endpoint | --endpoint)
        endpoint="$2"
        ;;
    -file | --file)
        file="$2"
        ;;
    -verbose | --verbose)
        verbose=1
        ;;
    -repo-token | --repo-token)
        repo_token="$2"
        ;;
    -ignore-errors | --ignore-errors)
        ignore_errors=1
        ;;
    -base-dir | --base-dir)
        base_dir="$2"
        ;;
    *) ;;
    esac
    shift
    shift
done

if test "${verbose:-0}" != "0"; then
        echo "Uploader Config:"
        echo "  --endpoint = ${endpoint}"
        echo "  --file = ${file}"
        echo "  --repo-token = ${repo_token}"
        echo "  --ignore-errors = ${ignore_errors}"
        echo "  --verbose = ${verbose}"
        echo "  --base-dir = ${base_dir}"
fi

########## GIT ##########
if test "${verbose:-0}" != "0"; then
    echo "Attempting to detect Git info ..."
fi
branch_names="$(git branch | xargs)"
IFS="\n"
read -r -a branches <<<"${branch_names}"
for branch in "${branches[@]}"; do
    if [[ ${branch} = "* (no branch)" ]]; then
        branch_name="(no branch)"
    elif [[ ${branch} == *"* "* ]]; then
        branch_name=$(echo "${branch}" | sed -rE 's|\* (\(HEAD detached at )?([\w\/\-\\]*)\)?|\2|' | sed -rE 's|([\w\/\-\\]*)\)|\1|')
    fi
done

if test "${verbose:-0}" != "0"; then
    echo "    Branch: ${branch_name}"
fi

# get commit sha
commit_sha=$(git log -1 --pretty=format:'%H' | xargs)

if test "${verbose:-0}" != "0"; then
    echo "    Commit SHA: ${commit_sha}"
fi

########## CI ##########
if test "${verbose:-0}" != "0"; then
    echo "Attempting to detect CI environment ..."
fi
ci_pr=""
ci_repo=""
ci_branch=""
ci_base_branch=""
ci_head_commit=""
if [ -n "$(printenv TRAVIS | xargs)" ]; then
    if test "${verbose:-0}" != "0"; then
        echo "  Detected TravisCI"
    fi
    ci_detected="travis-ci"
    ci_pr="$(printenv TRAVIS_PULL_REQUEST | xargs)"
    ci_job_id="$(printenv TRAVIS_JOB_ID | xargs)"
    ci_build_number="$(printenv TRAVIS_BUILD_NUMBER | xargs)"
elif [ -n "$(printenv GITHUB_ACTIONS | xargs)" ]; then
    if test "${verbose:-0}" != "0"; then
        echo "  Detected Github Actions"
    fi
    ci_detected="github-actions"
    ci_job_id="$(printenv GITHUB_RUN_ID | xargs)"
    ci_build_number="$(printenv GITHUB_RUN_NUMBER | xargs)"
    ci_base_branch="$(printenv GITHUB_BASE_REF | xargs)"
    ci_branch="$(printenv GITHUB_HEAD_REF | xargs)"
    ci_repo="$(printenv GITHUB_REPOSITORY | xargs)"

    github_ref="$(printenv GITHUB_REF | xargs)"
    github_event="$(printenv GITHUB_EVENT_NAME | xargs)"
    ci_head_commit="$(printenv GITHUB_SHA | xargs)"
    if [[ ${github_event} = "pull_request" ]]; then
        if test "${verbose:-0}" != "0"; then
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
    if test "${verbose:-0}" != "0"; then
        echo "  Detected CircleCI"
    fi
    ci_detected="circle-ci"
    ci_job_id="$(printenv CIRCLE_WORKFLOW_ID | xargs)"
    ci_build_number="$(printenv CIRCLE_WORKFLOW_ID | xargs)"
    ci_pr="$(printenv CIRCLE_PR_NUMBER | xargs)"
elif [ -n "$(printenv APPVEYOR | xargs)" ]; then
    if test "${verbose:-0}" != "0"; then
        echo "  Detected AppVeyer"
    fi
    ci_detected="appveyor"
    ci_pr="$(printenv APPVEYOR_PULL_REQUEST_NUMBER | xargs)"
    ci_branch="$(printenv APPVEYOR_REPO_BRANCH | xargs)"
    ci_job_id="$(printenv APPVEYOR_JOB_NUMBER | xargs)"
    ci_build_number="$(printenv APPVEYOR_BUILD_NUMBER | xargs)"
elif [ -n "$(printenv JENKINS_URL | xargs)" ]; then
    if test "${verbose:-0}" != "0"; then
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
    if test "${verbose:-0}" != "0"; then
        echo "  Detected ChipperCI"
    fi
    ci_detected="chipper-ci"
    ci_pr="$(printenv CI_COMMIT_TAG | xargs)" # todo figure out if this is correct (is it release, not PR?)
    ci_branch="$(printenv CI_COMMIT_BRANCH | xargs)"
elif [ -n "$(printenv COTTER_LOCAL | xargs)" ]; then
    if test "${verbose:-0}" != "0"; then
        echo "  Detected Local"
    fi
    ci_detected="local"
else
    if test "${verbose:-0}" != "0"; then
        echo "  Could not detect CI"

        if test "${ignore_errors:-0}" != "1"; then
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

########## COVERAGE FILE ##########
if test "${verbose:-0}" != "0"; then
    echo "Looking for coverage file ..."
fi
if test "$file" == ""; then
    if [ -f "build/logs/clover.xml" ]; then
        coverage_path="build/logs/clover.xml"
    else
        echo "  Could not determine Coverage file path, please verify that the file exists. Alternatively pass it with --file [PATH]"
        if test "${ignore_errors:-0}" != "1"; then
            exit 1
        else
            exit 0
        fi
    fi
else
    if [ ! -f "${file}" ]; then
        echo "  Passed --file '${file}' does not exist."
        if test "${ignore_errors:-0}" != "1"; then
            exit 1
        else
            exit 0
        fi
    fi
    coverage_path="${file}"
fi

if test "${verbose:-0}" != "0"; then
    echo "  Found at ${coverage_path}"
fi

########## INFO ##########
if test "$base_dir" == ""; then
    if test "${verbose:-0}" != "0"; then
        echo "No --base-dir set, setting to: $(pwd)"
    fi

    base_dir="$(pwd)"
fi

if [[ -z "${repo_token}" ]]; then
    repo_token=$(printenv REPO_TOKEN | xargs)
fi

# todo clean stuff we dont need
if test "${verbose:-0}" != "0"; then
    echo "Detected data:"
    echo "  Git Branch: ${branch_name}"
    echo "  Git Commit sha: ${commit_sha}"
    echo "  CI Provider: ${ci_detected}"
    echo "  CI JOB: ${ci_job_id}"
    echo "  CI Build: ${ci_build_number}"
    echo "  CI PR: ${ci_pr}"
    echo "  CI Head Commit: ${ci_head_commit}"
    echo "  CI Head Branch: ${ci_branch}"
    echo "  CI Base Branch: ${ci_base_branch}"
    echo "  CI Repo: ${ci_repo}"
    echo "  Repo Token: ${repo_token}"
    echo "  Base Dir: ${base_dir}"
fi

if test "${verbose:-0}" != "0"; then
    echo "Uploading coverage ..."
fi

UPLOAD_RESPONSE=$(curl --retry 5 --retry-max-time 60 --retry-all-errors \
    -F clover=@"${coverage_path}" \
    -F ci_provider="${ci_detected}" \
    -F ci_job="${ci_job_id}" \
    -F ci_build="${ci_build_number}" \
    -F repo_token="${repo_token}" \
    -F git_repo="${ci_repo}" \
    -F git_pr="${ci_pr}" \
    -F git_head_commit="${commit_sha}" \
    -F git_base_branch="${ci_base_branch}" \
    -F git_head_branch="${ci_branch}" \
    -F git_branch="${branch_name}" \
    -F base_dir="${base_dir}" \
    -s "${endpoint:-\"https://otterwise.app/ingress/upload\"}")

res=$?

if test "$res" != "0"; then
    echo "Upload of code coverage to OtterWise failed with cURL error $res"

    if test "${ignore_errors:-0}" != "1"; then
        exit "$res"
    fi
elif test "${verbose:-0}" != "0"; then
    echo "Coverage uploaded"
    echo "Curl Output: $UPLOAD_RESPONSE"
fi
