#!/usr/bin/env bash
# Checks the OpenVEX file read by the vulnerability scanners (Trivy and Grype).
# OpenVEX has no expiry field, so this script is what makes the exceptions expire:
#   - error (exit 1): a statement is malformed, or was last reviewed more than
#     MAX_AGE_DAYS calendar days ago (last_updated, else timestamp), or has a future date;
#   - warning: a package of a statement is not in the image anymore (needs the SBOM),
#     so the statement can be removed.
# Only "not_affected" statements with a justification, an impact statement and
# packages pinned to a version (pkg:type/namespace/name@version) are accepted.
# A Debian package with an epoch (version 1:...) needs two products: the version with the
# epoch, as in the SBOM (read by Grype), and the version without it (read by Trivy, which
# moves the epoch to a qualifier).
# To renew a statement after a review, set its last_updated to the review date.
# Usage: check-vex.sh <openvex.json> [sbom.cdx.json]
# VEX_TODAY (YYYY-MM-DD) replaces today's date, only to test the expiry locally.
set -euo pipefail

VEX="${1:?usage: check-vex.sh <openvex.json> [sbom.cdx.json]}"
SBOM="${2:-}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-30}"
TODAY="${VEX_TODAY:-$(date -u +%F)}"

# Package URLs in the image, without qualifiers (?arch=...&distro=...); a version with an
# epoch is also listed without it, so that both products of a Debian package are found
PURLS="null"
if [[ -n "${SBOM}" ]]; then
  PURLS="$(jq -c '[.. | objects | .purl? // empty | split("?")[0] | ., sub("@[0-9]+(%3A|:)"; "@")] | unique' "${SBOM}")"
fi

# One line per finding: level <TAB> vulnerability <TAB> message
FINDINGS="$(jq -r --arg today "${TODAY}" --argjson max "${MAX_AGE_DAYS}" --argjson purls "${PURLS}" '
  def day: .[0:10] + "T00:00:00Z" | fromdateiso8601;
  def justifications: ["component_not_present", "vulnerable_code_not_present",
    "vulnerable_code_not_in_execute_path", "vulnerable_code_cannot_be_controlled_by_adversary",
    "inline_mitigations_already_exist"];
  def line($level; $id; $msg): "\($level)\t\($id)\t\($msg)";

  .timestamp as $doc
  | if (."@context" // "" | startswith("https://openvex.dev/ns/")) | not
    then line("error"; "-"; "not an OpenVEX document (@context)") else empty end,
    if (.statements | type) != "array"
    then line("error"; "-"; "no statements array") else empty end,
    ((.statements // [])[]
      | (.vulnerability.name // "") as $id
      | (.last_updated // .timestamp // $doc // "") as $date
      | if $id == "" then line("error"; "-"; "statement without vulnerability.name") else empty end,
        if .status != "not_affected"
        then line("error"; $id; "status must be not_affected (found: \(.status))") else empty end,
        if (.justification // "") as $j | any(justifications[]; . == $j) | not
        then line("error"; $id; "missing or invalid justification") else empty end,
        if (.impact_statement // "") == ""
        then line("error"; $id; "missing impact_statement") else empty end,
        if (.products // []) == [] then line("error"; $id; "no products") else empty end,
        ((.products // [])[] | (."@id" // "") as $p
          | if ($p | test("^pkg:[a-z]+/[^@?#]+@[^@?#]+$")) | not
            then line("error"; $id; "product must be a package pinned to a version: \($p)")
            elif $purls != null and ($purls | index($p)) == null
            then line("warning"; $id; "\($p) is not in the image anymore: the statement can be removed")
            else empty end),
        if ($date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) | not
        then line("error"; $id; "missing or invalid date (last_updated or timestamp)")
        else ((($today | day) - ($date | day)) / 86400) as $age
          | if $age < 0 then line("error"; $id; "review date \($date[0:10]) is in the future")
            elif $age > $max
            then line("error"; $id; "expired: last reviewed on \($date[0:10]), \($age) days ago (limit: \($max) days)")
            else line("info"; $id; "last reviewed on \($date[0:10]), \($age) days ago (limit: \($max) days)")
            end
        end)
' "${VEX}")"

ERRORS=0
while IFS=$'\t' read -r LEVEL ID MESSAGE; do
  case "${LEVEL}" in
    error)   echo "::error title=VEX ${ID}::${MESSAGE}"; ERRORS=$((ERRORS + 1)) ;;
    warning) echo "::warning title=VEX ${ID}::${MESSAGE}" ;;
    info)    echo "${ID}: ${MESSAGE}" ;;
  esac
done <<< "${FINDINGS}"

if (( ERRORS > 0 )); then
  echo "VEX check failed with ${ERRORS} error(s)"
  exit 1
fi
echo "VEX check passed"
