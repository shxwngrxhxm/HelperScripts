#!/usr/bin/env bash
# Extract offline SSM Run Command artifacts.
# Source: /mnt/evidence | outputs: /cases/<source-instance-id>/actor_commands{,.index.tsv,.sha256}
set -Eeuo pipefail
export LC_ALL=C
IFS=$'\n\t'
umask 077
SOURCE_ROOT=/mnt/evidence
CASES_ROOT=${CASES_ROOT:-/cases}
CASE_NAME=''
WORK_ROOT=''
fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n $WORK_ROOT && -d $WORK_ROOT ]]; then rm -rf -- "$WORK_ROOT"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
(( EUID == 0 )) || fatal 'run as root.'
(( $# == 0 )) || fatal 'this script takes no arguments.'
for tool in findmnt realpath find sort awk sha256sum date stat mktemp flock cat tail od tr sed basename dirname chmod mv mkdir; do
   command -v "$tool" >/dev/null || fatal "Missing dependency: $tool"
done
SOURCE_ROOT=$(realpath -e -- "$SOURCE_ROOT")
opts=$(findmnt -rn -M "$SOURCE_ROOT" -o OPTIONS) || fatal 'Evidence must be an exact mountpoint.'
[[ ,$opts, == *,ro,* ]] || fatal 'Evidence mount is not read-only.'
CASES_ROOT=$(realpath -m -- "$CASES_ROOT")
case "$CASES_ROOT/" in "$SOURCE_ROOT/"*) fatal 'Output must be outside evidence.';; esac
SSM_ID_ROOT="$SOURCE_ROOT/var/lib/amazon/ssm"
if [[ -n ${SOURCE_INSTANCE_ID:-} ]]; then
    [[ $SOURCE_INSTANCE_ID =~ ^i-([0-9a-f]{8}|[0-9a-f]{17})$ ]] || fatal 'invalid SOURCE_INSTANCE_ID.'
    CASE_NAME=$SOURCE_INSTANCE_ID
else
    [[ -d $SSM_ID_ROOT && ! -L $SSM_ID_ROOT ]] || fatal 'No SSM instance directory. Set SOURCE_INSTANCE_ID explicitly.'
    id_root_resolved=$(realpath -e -- "$SSM_ID_ROOT")
    [[ $id_root_resolved == "$SOURCE_ROOT/"* ]] || fatal 'SSM path is not within the expected evidence path.'
    shopt -s nullglob
    candidates=()
    for candidate in "$SSM_ID_ROOT"/i-*; do
        [[ -d $candidate && ! -L $candidate ]] || continue 
        instance_id=${candidate##*/}
        [[ $instance_id =~ ^i-([0-9a-f]{8}|[0-9a-f]{17})$ ]] || continue
        candidates+=("$instance_id")
    done
    shopt -u nullglob
    (( ${#candidates[@]} == 1 )) || fatal 'Expected exactly one source instance ID in evidence. Set SOURCE_INSTANCE_ID explicitly after verifying the source.'
    CASE_NAME=${candidates[0]}
fi
CASE_DIR="$CASES_ROOT/$CASE_NAME"
mkdir -p -- "$CASE_DIR"
CASE_DIR=$(realpath -e -- "$CASE_DIR")
case "$CASE_DIR/" in "$SOURCE_ROOT/"*) fatal 'Output resolves INSIDE of evidence.';; esac
exec 9>"$CASE_DIR/.actor_commands.lock"
flock -n 9 || fatal 'Another extraction is running.'
for name in actor_commands actor_commands.index.tsv actor_commands.sha256; do
    [[ ! -L $CASE_DIR/$name ]] || fatal "Output is a symlink: $name"
done
WORK_ROOT=$(mktemp -d "$CASE_DIR/.actor_commands.work.XXXXXXXX")
#Reject paths resolving outside the mounted source. Dont follow final symlinks
safe_file() {
    local resolved
    [[ -f $1 && ! -L $1 && -r $1 ]] || return 1
    resolved=$(realpath -e -- "$1") || return 1
    [[ $resolved == "$SOURCE_ROOT/"* ]]
}
relative() { if [[ $1 == '-' ]]; then printf '-'; else printf '/%s' "${1#"$SOURCE_ROOT/"}"; fi; }
hash_file() { if [[ $1 == '-' ]]; then printf '-'; else sha256sum -- "$1" | awk '{print $1}'; fi; }
emit() {
    local last
    if [[ $1 == '-' ]]; then printf '[not present]\n'; return; fi
    cat -- "$1"
    if [[ ! -s $1 ]]; then printf '\n'; return; fi
    last=$(tail -c 1 -- "$1" | od -An -tu1 | tr -d '[:space:]')
    if [[ $last != 10 ]]; then printf '\n'; fi
}
HOSTNAME_STORED=unknown
if safe_file "$SOURCE_ROOT/etc/hostname"; then
    HOSTNAME_STORED=$(tr -d '\000\r\n\t' < "$SOURCE_ROOT/etc/hostname")
fi
SSM_ROOT="$SOURCE_ROOT/var/lib/amazon/ssm"
RECORDS="$WORK_ROOT/records.tsv"
: > "$RECORDS"
: > "$WORK_ROOT/commands.list"
if [[ -d $SSM_ROOT ]]; then
    resolved=$(realpath -e -- "$SSM_ROOT")
    [[ $resolved == "$SOURCE_ROOT/"* ]] || fatal 'SSM directory resolves outside evidence.'
    find -P "$SSM_ROOT" -xdev -type d -path '*/document/orchestration' -print0 > "$WORK_ROOT/orchestration.list"
    while IFS= read -r -d '' orchestration; do
        find -P "$orchestration" -mindepth 1 -maxdepth 1 -type d -print0 >> "$WORK_ROOT/commands.list"
    done < "$WORK_ROOT/orchestration.list"
fi
command_count=0
record_count=0
while IFS= read -r -d '' command_dir; do
    command_id=${command_dir##*/}
    [[ $command_id =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || continue
    ((command_count+=1))
    rel=${command_dir#"$SSM_ROOT/"}
    node=${rel%%/*}
    [[ $node != *$'\t'* && $node != *$'\n'* ]] || fatal 'Unsupported tab/newline in node path.'
    find -P "$command_dir" -xdev -type f \( -name _script.sh -o -name stdout -o -name stderr \) -print0 > "$WORK_ROOT/files.list"
    : > "$WORK_ROOT/steps.unsorted"
    earliest=''
    while IFS= read -r -d '' file; do
        safe_file "$file" || fatal "Unsafe or unreadable artifact: $file"
        [[ $file != *$'\t'* && $file != *$'\n'* ]] || fatal 'Unsupported tab/newline in artifact path.'
        printf '%s\0' "${file%/*}" >> "$WORK_ROOT/steps.unsorted"
        epoch=$(stat -c %Y -- "$file")
        if [[ -z $earliest ]] || (( epoch < earliest )); then earliest=$epoch; fi
    done < "$WORK_ROOT/files.list"
    sort -zu "$WORK_ROOT/steps.unsorted" > "$WORK_ROOT/steps.list"
    if [[ ! -s $WORK_ROOT/steps.list ]]; then printf '%s\0' "$command_dir" > "$WORK_ROOT/steps.list"; fi
    if [[ -z $earliest ]]; then earliest=$(stat -c %Y -- "$command_dir"); basis=command-directory-mtime; else basis='earliest-artifact-mtime'; fi
    stamp=$(date -u -d "@$earliest" '+%Y-%m-%d %H:%M:%S')
    while IFS= read -r -d '' step; do
        step_rel=${step#"$command_dir/"}
        [[ $step != "$command_dir" ]] || step_rel=.
        script_path=-; stdout_path=-; stderr_path=-
        for name in _script.sh stdout stderr; do
            file="$step/$name"
            if [[ -e $file || -L $file ]]; then
                safe_file "$file" || fatal "Unsafe or unreadable artifact: $file"
                case $name in _script.sh) script_path=$file;; stdout) stdout_path=$file;; stderr) stderr_path=$file;; esac
            fi
        done
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$earliest" "$stamp" "$basis" "$command_id" "$node" "$step_rel" "$script_path" "$stdout_path" "$stderr_path" >> "$RECORDS"
        ((record_count+=1))
    done < "$WORK_ROOT/steps.list"
done < "$WORK_ROOT/commands.list"
sort -t $'\t' -k1,1n -k4,4 -k5,5 -k6,6 "$RECORDS" > "$WORK_ROOT/sorted.tsv"
REPORT="$WORK_ROOT/actor_commands"
INDEX="$WORK_ROOT/actor_commands.index.tsv"
: > "$REPORT"
printf 'case\tsource_root\tstored_hostname\tmanaged_node_id\tcommand_id\ttimestamp_utc\ttimestamp_basis\tstep\tscript_path\tscript_sha256\tstdout_path\tstdout_sha256\tstderr_path\tstderr_sha256\n' > "$INDEX"
while IFS=$'\t' read -r epoch stamp basis command_id node step script_path stdout_path stderr_path; do
    {
        printf '%s\n' '================================================================='
        printf 'CMD %s %s UTC\nNODE %s STEP %s\nTIME BASIS %s (not confirmed execution time)\n' "$command_id" "$stamp" "$node" "$step" "$basis"
        printf '%s\n' '------------------------- SCRIPT ------------------------------'
        emit "$script_path"
        printf '%s\n' '------------------------- STDOUT ------------------------------'
        emit "$stdout_path"
        printf '%s\n' '------------------------- STDERR ------------------------------'
        emit "$stderr_path"
      } >> "$REPORT"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$CASE_NAME" "$SOURCE_ROOT" "$HOSTNAME_STORED" "$node" "$command_id" "$stamp" "$basis" "$step" \
            "$(relative "$script_path")" "$(hash_file "$script_path")" \
            "$(relative "$stdout_path")" "$(hash_file "$stdout_path")" \
            "$(relative "$stderr_path")" "$(hash_file "$stderr_path")" >> "$INDEX"
done < "$WORK_ROOT/sorted.tsv"
(cd "$WORK_ROOT"; sha256sum actor_commands actor_commands.index.tsv > actor_commands.sha256)
for name in actor_commands actor_commands.index.tsv actor_commands.sha256; do
    chmod 0600 "$WORK_ROOT/$name"
    mv -fT -- "$WORK_ROOT/$name" "$CASE_DIR/$name"
done
printf 'Completed: commands=%d records=%d\nOutput: %s\n' "$command_count" "$record_count" "$CASE_DIR"
printf 'Timestamps are filesystem metadata, not confirmed execution time. Agent logs not parsed.\n'
