function kv --description "Save, restore, list, clear, or migrate llama-server KV cache slots"
    set -l base_dir "/mnt/dat/Tools/Artificial Intelligence/kv-slots"
    if set -q KV_DIR; and test -n "$KV_DIR"
        set base_dir "$KV_DIR"
    else if set -q KV_PERM_DIR; and test -n "$KV_PERM_DIR"
        set base_dir "$KV_PERM_DIR"
    end

    set -l tmp_dir "/tmp"
    if set -q KV_TMP_DIR; and test -n "$KV_TMP_DIR"
        set tmp_dir "$KV_TMP_DIR"
    end

    set -l server_save_dir "/mnt/dat/kv-slots"
    if set -q KV_SERVER_DIR; and test -n "$KV_SERVER_DIR"
        set server_save_dir "$KV_SERVER_DIR"
    end

    set -l default_url "http://127.0.0.1:5001"
    if set -q KV_SERVER_URL; and test -n "$KV_SERVER_URL"
        set default_url "$KV_SERVER_URL"
    end

    set -l alias_file "$base_dir/aliases.tsv"
    set -l perm_manifest "$base_dir/kv_manifest.tsv"
    set -l tmp_manifest "$tmp_dir/kv_manifest.tsv"

    mkdir -p "$base_dir" "$tmp_dir" "$server_save_dir"
    touch "$alias_file" "$perm_manifest" "$tmp_manifest"

    function _kv_print_help
        echo "Usage:"
        echo "  kv save <name|rel/path> [-a <alias>] [-s <slot>] [-u <url>] [-m <model>] [-p] [-t] [-v] [-h]"
        echo "  kv load <pattern|alias|name|rel/path> [-s <slot>] [-u <url>] [-m <model>] [-f] [-p] [-t] [-v] [-h]"
        echo "  kv list [pattern] [-p] [-t] [-v] [-h]"
        echo "  kv clear [pattern1 pattern2 ...] [-s <slot>] [-u <url>] [-e] [-p] [-t] [-v] [-h]"
        echo "  kv migrate [pattern] [out_pattern] [-p|-t] [-v] [-h]"
        echo ""
        echo "Flags:"
        echo "  -p, --perm                     Target permanent directory (save default; migrate destination)"
        echo "  -t, --tmp                      Target temporary directory (clear default; migrate destination)"
        echo "  -a, --alias <name>             Assign or update an alias in aliases.tsv"
        echo "  -s, --slot <id>                Target slot ID (default: 0)"
        echo "  -u, --url <url>                Target llama-server URL (default: http://127.0.0.1:5001)"
        echo "  -m, --model <filter>           Select endpoint matching model filter across url and KV_ENDPOINTS"
        echo "  -f, --force                    Skip compatibility warnings during load"
        echo "  -e, --erase                    Erase live slot on server during clear"
        echo "  -v, --verbose, --verbose-flag  Print resolved flags, paths, and settings"
        echo "  -h, --help                     Show this help message"
        echo ""
        echo "Defaults & Environment:"
        echo "  KV_DIR / KV_PERM_DIR           Permanent directory (default: /mnt/dat/Tools/Artificial Intelligence/kv-slots)"
        echo "  KV_TMP_DIR                     Temporary directory (default: /tmp)"
        echo "  KV_SERVER_DIR                  Server --slot-save-path directory (default: /mnt/dat/kv-slots)"
        echo "  KV_SERVER_URL                  Default server URL (default: http://127.0.0.1:5001)"
        echo "  KV_ENDPOINTS                   Comma- or space-separated extra server URLs for -m lookup"
        echo "  Wildcards (*, ?, [...])         Supported in load, list, clear, and migrate (quote in shell)"
    end

    function _kv_register_snapshot --argument-names manifest_file full_path rel_id
        set -l tmp_m "$manifest_file.tmp"
        awk -F'\t' -v p="$full_path" '$1 != p {print $0}' "$manifest_file" > "$tmp_m"
        printf '%s\t%s\n' "$full_path" "$rel_id" >> "$tmp_m"
        mv -f "$tmp_m" "$manifest_file"
    end

    function _kv_unregister_snapshot --argument-names manifest_file full_path
        set -l tmp_m "$manifest_file.tmp"
        awk -F'\t' -v p="$full_path" '$1 != p {print $0}' "$manifest_file" > "$tmp_m"
        mv -f "$tmp_m" "$manifest_file"
    end

    function _kv_update_alias_path --argument-names alias_path old_p new_p
        set -l tmp_a "$alias_path.tmp"
        awk -F'\t' -v o="$old_p" -v n="$new_p" 'BEGIN{OFS="\t"} {if ($2 == o) $2 = n; print $1, $2}' "$alias_path" > "$tmp_a"
        mv -f "$tmp_a" "$alias_path"
    end

    function _kv_apply_out_pattern --argument-names out_pat src_rel src_base
        set -l clean_out (string replace -r '^/+' '' -- "$out_pat")
        if string match -q '*`**' -- "$clean_out"
            # Handle '*' wildcard replacement using stem or relative path
            set -l stem (string replace -r '\.bin$' '' -- "$src_base")
            set -l res (string replace -a '*' "$stem" -- "$clean_out")
            if not string match -q '*.bin' -- "$res"
                set res "$res.bin"
            end
            echo "$res"
            return 0
        end
        if string match -q '*/' -- "$out_pat"
            set -l bname (basename "$src_rel")
            set -l joined "$clean_out$bname"
            if not string match -q '*.bin' -- "$joined"
                set joined "$joined.bin"
            end
            echo "$joined"
            return 0
        end
        if not string match -q '*.bin' -- "$clean_out"
            set clean_out "$clean_out.bin"
        end
        echo "$clean_out"
    end

    if test (count $argv) -lt 1
        _kv_print_help
        return 1
    end

    set -l subcmd $argv[1]
    if contains -- "$subcmd" -h --help
        _kv_print_help
        return 0
    end

    set -l use_perm 0
    set -l use_tmp 0
    set -l force_load 0
    set -l erase_slot 0
    set -l verbose_flag 0
    set -l slot_id "0"
    set -l target_url "$default_url"
    set -l model_filter ""
    set -l alias_name ""
    set -l targets

    set -l i 2
    while test $i -le (count $argv)
        set -l arg $argv[$i]
        switch $arg
            case -h --help
                _kv_print_help
                return 0
            case -v --verbose --verbose-flag
                set verbose_flag 1
            case -a --alias
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "Missing value after $arg" >&2
                    return 1
                end
                set alias_name $argv[$i]
            case -s --slot
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "Missing value after $arg" >&2
                    return 1
                end
                set slot_id $argv[$i]
            case -u --url
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "Missing value after $arg" >&2
                    return 1
                end
                set target_url (string replace -r '/+$' '' -- "$argv[$i]")
            case -m --model
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "Missing value after $arg" >&2
                    return 1
                end
                set model_filter $argv[$i]
            case -f --force
                set force_load 1
            case -e --erase
                set erase_slot 1
            case -p --perm
                set use_perm 1
            case -t --tmp
                set use_tmp 1
            case '-*'
                set -l chars (string split '' -- (string sub -s 2 -- "$arg"))
                set -l j 1
                while test $j -le (count $chars)
                    switch $chars[$j]
                        case h
                            _kv_print_help
                            return 0
                        case v
                            set verbose_flag 1
                        case p
                            set use_perm 1
                        case t
                            set use_tmp 1
                        case f
                            set force_load 1
                        case e
                            set erase_slot 1
                        case a
                            if test $j -lt (count $chars)
                                set alias_name (string join '' -- $chars[(math $j + 1)..-1])
                                break
                            else
                                set i (math $i + 1)
                                if test $i -gt (count $argv)
                                    echo "Missing value after -a" >&2
                                    return 1
                                end
                                set alias_name $argv[$i]
                            end
                        case s
                            if test $j -lt (count $chars)
                                set slot_id (string join '' -- $chars[(math $j + 1)..-1])
                                break
                            else
                                set i (math $i + 1)
                                if test $i -gt (count $argv)
                                    echo "Missing value after -s" >&2
                                    return 1
                                end
                                set slot_id $argv[$i]
                            end
                        case u
                            if test $j -lt (count $chars)
                                set target_url (string replace -r '/+$' '' -- (string join '' -- $chars[(math $j + 1)..-1]))
                                break
                            else
                                set i (math $i + 1)
                                if test $i -gt (count $argv)
                                    echo "Missing value after -u" >&2
                                    return 1
                                end
                                set target_url (string replace -r '/+$' '' -- "$argv[$i]")
                            end
                        case m
                            if test $j -lt (count $chars)
                                set model_filter (string join '' -- $chars[(math $j + 1)..-1])
                                break
                            else
                                set i (math $i + 1)
                                if test $i -gt (count $argv)
                                    echo "Missing value after -m" >&2
                                    return 1
                                end
                                set model_filter $argv[$i]
                            end
                        case '*'
                            echo "Unknown option: -$chars[$j]" >&2
                            return 1
                    end
                    set j (math $j + 1)
                end
            case '*'
                set -a targets $arg
        end
        set i (math $i + 1)
    end

    # Collect valid tracked snapshots from each store's manifest
    set -l perm_entries
    if test -s "$perm_manifest"
        set -l kept_perm_m
        while read -l m_path m_rel
            if test -n "$m_path"; and test -f "$m_path"
                if test -z "$m_rel"
                    set m_rel (string replace -r "^$base_dir/" "" -- "$m_path")
                end
                set -a perm_entries "$m_path\t$m_rel"
                set -a kept_perm_m "$m_path\t$m_rel"
            end
        end < "$perm_manifest"
        printf '%s\n' $kept_perm_m > "$perm_manifest"
    end

    set -l tmp_entries
    if test -s "$tmp_manifest"
        set -l kept_tmp_m
        while read -l m_path m_rel
            if test -n "$m_path"; and test -f "$m_path"
                if test -z "$m_rel"
                    set m_rel (basename "$m_path")
                end
                set -a tmp_entries "$m_path\t$m_rel"
                set -a kept_tmp_m "$m_path\t$m_rel"
            end
        end < "$tmp_manifest"
        printf '%s\n' $kept_tmp_m > "$tmp_manifest"
    end

    if test $use_perm -eq 0 -a $use_tmp -eq 0
        switch $subcmd
            case save
                set use_perm 1
            case clear
                set use_tmp 1
            case list load restore migrate
                set use_perm 1
                set use_tmp 1
        end
    end

    if test -n "$model_filter"
        set -l candidate_urls "$target_url"
        if set -q KV_ENDPOINTS; and test -n "$KV_ENDPOINTS"
            for ep in (string split -n ',' -- (string replace -a ' ' ',' -- "$KV_ENDPOINTS"))
                set -l clean_ep (string replace -r '/+$' '' -- "$ep")
                if test -n "$clean_ep"; and not contains -- "$clean_ep" $candidate_urls
                    set -a candidate_urls "$clean_ep"
                end
            end
        end
        set -l matched_url ""
        for ep in $candidate_urls
            set -l props_json (curl -fsS --max-time 2 "$ep/props" 2>/dev/null)
            if test -z "$props_json"
                continue
            end
            set -l ep_model (printf '%s' "$props_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("model_path") or d.get("model_alias") or d.get("model") or "")
except Exception:
    pass
')
            if string match -qi "*$model_filter*" -- "$ep_model"
                set matched_url "$ep"
                break
            end
        end
        if test -n "$matched_url"
            set target_url "$matched_url"
        else
            echo "No running endpoint matched model filter '$model_filter'" >&2
            return 1
        end
    end

    if test $verbose_flag -eq 1
        echo "[verbose] subcommand   : $subcmd" >&2
        echo "[verbose] perm (-p)      : $use_perm" >&2
        echo "[verbose] tmp (-t)       : $use_tmp" >&2
        echo "[verbose] alias (-a)     : $alias_name" >&2
        echo "[verbose] slot (-s)      : $slot_id" >&2
        echo "[verbose] url (-u)       : $target_url" >&2
        echo "[verbose] model (-m)     : $model_filter" >&2
        echo "[verbose] force (-f)     : $force_load" >&2
        echo "[verbose] erase (-e)     : $erase_slot" >&2
        echo "[verbose] base_dir       : $base_dir" >&2
        echo "[verbose] tmp_dir        : $tmp_dir" >&2
        echo "[verbose] server_save_dir: $server_save_dir" >&2
        echo "[verbose] targets        : $targets" >&2
    end

    switch $subcmd
        case list
            set -l filter_pat ""
            if test (count $targets) -ge 1
                set filter_pat $targets[1]
            end

            if test $use_perm -eq 1
                echo "=== Aliases ==="
                set -l printed_alias 0
                if test -s "$alias_file"
                    while read -l a_name a_path
                        if test -z "$a_name"; or test -z "$a_path"
                            continue
                        end
                        if test -n "$filter_pat"; and not string match -q "$filter_pat" -- "$a_name"
                            continue
                        end
                        set -l status_lbl "missing"
                        if test -f "$a_path"
                            set status_lbl "ok"
                        end
                        printf "  %-16s -> %s [%s]\n" "$a_name" "$a_path" "$status_lbl"
                        set printed_alias 1
                    end < "$alias_file"
                end
                if test $printed_alias -eq 0
                    echo "  (none)"
                end

                echo ""
                echo "=== Permanent KV Snapshots ($base_dir) ==="
                set -l printed_perm 0
                for entry in $perm_entries
                    set -l parts (string split -m 1 \t -- "$entry")
                    set -l f $parts[1]
                    set -l rel $parts[2]
                    set -l no_ext (string replace -r '\.bin$' '' -- "$rel")
                    if test -n "$filter_pat"
                        if not string match -q "$filter_pat" -- "$rel"; and not string match -q "$filter_pat" -- "$no_ext"
                            continue
                        end
                    end
                    set -l sz (du -h "$f" | awk '{print $1}')
                    set -l meta_path "$f.meta"
                    set -l meta_info ""
                    if test -f "$meta_path"
                        set meta_info (awk -F'\t' '$1=="model"{m=$2} $1=="kv"{k=$2} END{if (m!="") printf " (%s, %s)", m, k}' "$meta_path")
                    end
                    printf "  %-36s %8s%s\n" "$rel" "$sz" "$meta_info"
                    set printed_perm 1
                end
                if test $printed_perm -eq 0
                    echo "  (no tracked .bin snapshots)"
                end
            end

            if test $use_tmp -eq 1
                if test $use_perm -eq 1
                    echo ""
                end
                echo "=== Temp KV Snapshots ($tmp_dir) ==="
                set -l printed_tmp 0
                for entry in $tmp_entries
                    set -l parts (string split -m 1 \t -- "$entry")
                    set -l f $parts[1]
                    set -l rel $parts[2]
                    set -l no_ext (string replace -r '\.bin$' '' -- "$rel")
                    if test -n "$filter_pat"
                        if not string match -q "$filter_pat" -- "$rel"; and not string match -q "$filter_pat" -- "$no_ext"
                            continue
                        end
                    end
                    set -l sz (du -h "$f" | awk '{print $1}')
                    set -l meta_path "$f.meta"
                    set -l meta_info ""
                    if test -f "$meta_path"
                        set meta_info (awk -F'\t' '$1=="model"{m=$2} $1=="kv"{k=$2} END{if (m!="") printf " (%s, %s)", m, k}' "$meta_path")
                    end
                    printf "  %-36s %8s%s\n" "$f" "$sz" "$meta_info"
                    set printed_tmp 1
                end
                if test $printed_tmp -eq 0
                    echo "  (no tracked .bin snapshots in $tmp_dir)"
                end
            end

        case save
            if test (count $targets) -lt 1
                echo "Missing target name or relative path for save" >&2
                return 1
            end

            set -l target $targets[1]
            set -l clean_rel (string replace -r '^/+' '' -- "$target")
            if not string match -q '*.bin' -- "$clean_rel"
                set clean_rel "$clean_rel.bin"
            end

            set -l perm_path "$base_dir/$clean_rel"
            set -l flat_name (string replace -a '/' '_' -- "$clean_rel")
            set -l tmp_path "$tmp_dir/$flat_name"

            set -l stage_name "kv_stage_"$slot_id"_(random).bin"
            set -l stage_full "$server_save_dir/$stage_name"

            set -l props_json (curl -fsS --max-time 3 "$target_url/props" 2>/dev/null)
            set -l slot_json (curl -fsS --max-time 3 "$target_url/slots/$slot_id" 2>/dev/null)
            set -l meta_lines (printf '%s\n%s\n' "$props_json" "$slot_json" | python3 -c '
import json, sys

raw = sys.stdin.read().strip().splitlines()
props = {}
slot = {}
for line in raw:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if isinstance(obj, dict):
            if "default_generation_settings" in obj or "model_path" in obj:
                props = obj
            elif "id" in obj or "n_ctx" in obj or "params" in obj:
                slot = obj
    except Exception:
        pass

dgs = props.get("default_generation_settings", {}) if isinstance(props.get("default_generation_settings"), dict) else {}
sparams = slot.get("params", {}) if isinstance(slot.get("params"), dict) else {}

model_val = props.get("model_path") or props.get("model_alias") or props.get("model") or ""
type_k = dgs.get("type_k") or sparams.get("type_k") or props.get("type_k") or ""
type_v = dgs.get("type_v") or sparams.get("type_v") or props.get("type_v") or ""
n_ctx = slot.get("n_ctx") or dgs.get("n_ctx") or props.get("n_ctx") or ""
n_tokens = slot.get("n_tokens") or slot.get("n_past") or ""

print(f"url\t{sys.argv[1]}")
print(f"slot\t{sys.argv[2]}")
print(f"model\t{model_val}")
print(f"kv\tk={type_k},v={type_v}")
print(f"type_k\t{type_k}")
print(f"type_v\t{type_v}")
print(f"n_ctx\t{n_ctx}")
print(f"n_tokens\t{n_tokens}")
' "$target_url" "$slot_id")

            set -l resp (curl -s -w "\n%{http_code}" -X POST "$target_url/slots/$slot_id?action=save" \
                -H "Content-Type: application/json" \
                -d "{\"filename\": \"$stage_name\"}")
            set -l code (string split -r \n -- $resp)[-1]

            if test "$code" -lt 200 -o "$code" -ge 300; or not test -f "$stage_full"
                echo "Failed to save slot $slot_id on $target_url (HTTP $code)" >&2
                echo $resp >&2
                return 1
            end

            set -l primary_path ""
            if test $use_perm -eq 1
                mkdir -p (dirname "$perm_path")
                if test $use_tmp -eq 1
                    cp -f "$stage_full" "$perm_path"
                    mv -f "$stage_full" "$tmp_path"
                    printf '%s\n' $meta_lines > "$perm_path.meta"
                    printf '%s\n' $meta_lines > "$tmp_path.meta"
                    _kv_register_snapshot "$perm_manifest" "$perm_path" "$clean_rel"
                    _kv_register_snapshot "$tmp_manifest" "$tmp_path" "$flat_name"
                    echo "Saved KV cache (slot $slot_id) -> $perm_path"
                    echo "Saved KV cache (slot $slot_id) -> $tmp_path"
                    set primary_path "$perm_path"
                else
                    mv -f "$stage_full" "$perm_path"
                    printf '%s\n' $meta_lines > "$perm_path.meta"
                    _kv_register_snapshot "$perm_manifest" "$perm_path" "$clean_rel"
                    echo "Saved KV cache (slot $slot_id) -> $perm_path"
                    set primary_path "$perm_path"
                end
            else if test $use_tmp -eq 1
                mv -f "$stage_full" "$tmp_path"
                printf '%s\n' $meta_lines > "$tmp_path.meta"
                _kv_register_snapshot "$tmp_manifest" "$tmp_path" "$flat_name"
                echo "Saved KV cache (slot $slot_id) -> $tmp_path"
                set primary_path "$tmp_path"
            end

            if test -n "$alias_name"; and test -n "$primary_path"
                set -l tmp_aliases "$alias_file.tmp"
                awk -F'\t' -v k="$alias_name" '$1 != k {print $0}' "$alias_file" > "$tmp_aliases"
                printf '%s\t%s\n' "$alias_name" "$primary_path" >> "$tmp_aliases"
                mv -f "$tmp_aliases" "$alias_file"
                echo "Alias '$alias_name' -> $primary_path"
            end

        case load restore
            if test (count $targets) -lt 1
                echo "Missing target alias, name, or relative path for load" >&2
                return 1
            end

            set -l pat $targets[1]
            set -l clean_pat (string replace -r '^/+' '' -- "$pat")
            set -l flat_pat (string replace -a '/' '_' -- "$clean_pat")
            set -l matches

            # 1. Check matching aliases pointing to tracked snapshots
            if test -s "$alias_file"
                while read -l a_name a_path
                    if test -z "$a_name"; or test -z "$a_path"; or not test -f "$a_path"
                        continue
                    end
                    if string match -q "$pat" -- "$a_name"
                        set -l in_perm (string match -q "$base_dir/*" -- "$a_path"; and echo 1; or echo 0)
                        set -l in_tmp (string match -q "$tmp_dir/*" -- "$a_path"; and echo 1; or echo 0)
                        set -l tracked_ok 0
                        if test $in_perm -eq 1; and grep -Fxq -- "$a_path" (for e in $perm_entries; string split -m 1 \t -- "$e" | head -n 1; end) 2>/dev/null
                            set tracked_ok 1
                        end
                        if test $in_tmp -eq 1; and grep -Fxq -- "$a_path" (for e in $tmp_entries; string split -m 1 \t -- "$e" | head -n 1; end) 2>/dev/null
                            set tracked_ok 1
                        end
                        if test $tracked_ok -eq 1
                            if test \( $use_perm -eq 1 -a $in_perm -eq 1 \) -o \( $use_tmp -eq 1 -a $in_tmp -eq 1 \)
                                if not contains -- "$a_path" $matches
                                    set -a matches "$a_path"
                                end
                            end
                        end
                    end
                end < "$alias_file"
            end

            # 2. Match tracked temp snapshots
            if test $use_tmp -eq 1
                for entry in $tmp_entries
                    set -l parts (string split -m 1 \t -- "$entry")
                    set -l f $parts[1]
                    set -l bname (basename "$f")
                    set -l bname_no_ext (string replace -r '\.bin$' '' -- "$bname")
                    if string match -q "$clean_pat" -- "$bname"; or string match -q "$clean_pat.bin" -- "$bname"; or string match -q "$clean_pat" -- "$bname_no_ext"; or string match -q "$flat_pat" -- "$bname"; or string match -q "$flat_pat.bin" -- "$bname"
                        if not contains -- "$f" $matches
                            set -a matches "$f"
                        end
                    end
                end
            end

            # 3. Match tracked permanent snapshots
            if test $use_perm -eq 1
                for entry in $perm_entries
                    set -l parts (string split -m 1 \t -- "$entry")
                    set -l f $parts[1]
                    set -l rel $parts[2]
                    set -l rel_no_ext (string replace -r '\.bin$' '' -- "$rel")
                    set -l bname (basename "$f")
                    set -l bname_no_ext (string replace -r '\.bin$' '' -- "$bname")
                    if string match -q "$clean_pat" -- "$rel"; or string match -q "$clean_pat.bin" -- "$rel"; or string match -q "$clean_pat" -- "$rel_no_ext"; or string match -q "$clean_pat" -- "$bname"; or string match -q "$clean_pat" -- "$bname_no_ext"
                        if not contains -- "$f" $matches
                            set -a matches "$f"
                        end
                    end
                end
            end

            if test (count $matches) -eq 0
                echo "No tracked KV cache snapshot matched '$pat'" >&2
                return 1
            end

            set -l src_path ""
            if test (count $matches) -eq 1
                set src_path $matches[1]
            else
                echo "Multiple snapshots matched '$pat':"
                set -l idx 1
                for m in $matches
                    echo "  [$idx] $m"
                    set idx (math $idx + 1)
                end
                read -l -P "Select number (1-"(count $matches)", 0 to cancel): " choice
                if test -z "$choice"; or test "$choice" -lt 1 -o "$choice" -gt (count $matches) 2>/dev/null
                    echo "Cancelled."
                    return 1
                end
                set src_path $matches[$choice]
            end

            set -l meta_file "$src_path.meta"
            if test -f "$meta_file"; and test $force_load -eq 0
                set -l saved_model (awk -F'\t' '$1=="model"{print $2; exit}' "$meta_file")
                set -l saved_tk (awk -F'\t' '$1=="type_k"{print $2; exit}' "$meta_file")
                set -l saved_tv (awk -F'\t' '$1=="type_v"{print $2; exit}' "$meta_file")
                set -l saved_tokens (awk -F'\t' '$1=="n_tokens"{print $2; exit}' "$meta_file")

                set -l live_props (curl -fsS --max-time 3 "$target_url/props" 2>/dev/null)
                set -l live_slot (curl -fsS --max-time 3 "$target_url/slots/$slot_id" 2>/dev/null)
                set -l live_check (printf '%s\n%s\n' "$live_props" "$live_slot" | python3 -c '
import json, sys

raw = sys.stdin.read().strip().splitlines()
props = {}
slot = {}
for line in raw:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if isinstance(obj, dict):
            if "default_generation_settings" in obj or "model_path" in obj:
                props = obj
            elif "id" in obj or "n_ctx" in obj or "params" in obj:
                slot = obj
    except Exception:
        pass

dgs = props.get("default_generation_settings", {}) if isinstance(props.get("default_generation_settings"), dict) else {}
sparams = slot.get("params", {}) if isinstance(slot.get("params"), dict) else {}

model_val = props.get("model_path") or props.get("model_alias") or props.get("model") or ""
type_k = dgs.get("type_k") or sparams.get("type_k") or props.get("type_k") or ""
type_v = dgs.get("type_v") or sparams.get("type_v") or props.get("type_v") or ""
n_ctx = slot.get("n_ctx") or dgs.get("n_ctx") or props.get("n_ctx") or ""

print(f"model={model_val}")
print(f"type_k={type_k}")
print(f"type_v={type_v}")
print(f"n_ctx={n_ctx}")
')
                set -l live_model (string match -r '^model=(.*)$' -- $live_check)[2]
                set -l live_tk (string match -r '^type_k=(.*)$' -- $live_check)[2]
                set -l live_tv (string match -r '^type_v=(.*)$' -- $live_check)[2]
                set -l live_ctx (string match -r '^n_ctx=(.*)$' -- $live_check)[2]

                set -l warnings
                if test -n "$saved_model"; and test -n "$live_model"; and test "$saved_model" != "$live_model"
                    set -a warnings "Model mismatch: snapshot has '$saved_model', server has '$live_model'"
                end
                if test -n "$saved_tk"; and test -n "$live_tk"; and test "$saved_tk" != "$live_tk"
                    set -a warnings "KV K-type mismatch: snapshot has '$saved_tk', server has '$live_tk'"
                end
                if test -n "$saved_tv"; and test -n "$live_tv"; and test "$saved_tv" != "$live_tv"
                    set -a warnings "KV V-type mismatch: snapshot has '$saved_tv', server has '$live_tv'"
                end
                if test -n "$saved_tokens"; and test -n "$live_ctx"
                    if test "$saved_tokens" -gt "$live_ctx" 2>/dev/null
                        set -a warnings "Context size mismatch: snapshot has $saved_tokens tokens, slot $slot_id allows $live_ctx"
                    end
                end

                if test (count $warnings) -gt 0
                    echo "Compatibility check warnings for '$src_path':" >&2
                    for w in $warnings
                        echo "  - $w" >&2
                    end
                    read -l -P "Restore anyway? [y/N]: " ans
                    if not string match -ri '^y(es)?$' -- "$ans"
                        echo "Cancelled."
                        return 1
                    end
                end
            end

            set -l active_name "_active_restore_slot_$slot_id.bin"
            cp -f "$src_path" "$server_save_dir/$active_name"

            set -l resp (curl -s -w "\n%{http_code}" -X POST "$target_url/slots/$slot_id?action=restore" \
                -H "Content-Type: application/json" \
                -d "{\"filename\": \"$active_name\"}")
            set -l code (string split -r \n -- $resp)[-1]

            if test "$code" -lt 200 -o "$code" -ge 300
                echo "Failed to restore slot $slot_id on $target_url from '$src_path' (HTTP $code)" >&2
                echo $resp >&2
                return 1
            end

            echo "Restored KV cache (slot $slot_id @ $target_url) <- $src_path"

        case migrate
            # Determine migration direction:
            # explicit_dir: 0 = opposite store per item, 1 = destination is perm, 2 = destination is tmp
            set -l explicit_dir 0
            set -l has_p_flag 0
            set -l has_t_flag 0
            for raw_arg in $argv[2..-1]
                if test "$raw_arg" = "-p" -o "$raw_arg" = "--perm"
                    set has_p_flag 1
                else if test "$raw_arg" = "-t" -o "$raw_arg" = "--tmp"
                    set has_t_flag 1
                else if string match -r '^-[^-]*p' -- "$raw_arg"
                    set has_p_flag 1
                else if string match -r '^-[^-]*t' -- "$raw_arg"
                    set has_t_flag 1
                end
            end

            if test $has_p_flag -eq 1 -a $has_t_flag -eq 0
                set explicit_dir 1
            else if test $has_t_flag -eq 1 -a $has_p_flag -eq 0
                set explicit_dir 2
            end

            set -l pat ""
            set -l out_pat ""
            if test (count $targets) -ge 1
                set pat $targets[1]
            end
            if test (count $targets) -ge 2
                set out_pat $targets[2]
            end

            # Build candidate list: store_tag\tf\trel
            set -l candidates
            for entry in $perm_entries
                set -l parts (string split -m 1 \t -- "$entry")
                set -a candidates "perm\t$parts[1]\t$parts[2]"
            end
            for entry in $tmp_entries
                set -l parts (string split -m 1 \t -- "$entry")
                set -a candidates "tmp\t$parts[1]\t$parts[2]"
            end

            set -l migrated_count 0
            for cand in $candidates
                set -l cols (string split -m 2 \t -- "$cand")
                set -l store $cols[1]
                set -l src_f $cols[2]
                set -l src_rel $cols[3]
                set -l bname (basename "$src_f")
                set -l bname_no_ext (string replace -r '\.bin$' '' -- "$bname")
                set -l rel_no_ext (string replace -r '\.bin$' '' -- "$src_rel")
                set -l rel_dir (dirname "$src_rel")

                if test -n "$pat"
                    set -l clean_pat (string replace -r '^/+' '' -- "$pat")
                    set -l flat_pat (string replace -a '/' '_' -- "$clean_pat")
                    if not string match -q "$clean_pat" -- "$src_rel"; and not string match -q "$clean_pat.bin" -- "$src_rel"; and not string match -q "$clean_pat" -- "$rel_no_ext"; and not string match -q "$clean_pat" -- "$rel_dir"; and not string match -q "$clean_pat" -- "$bname"; and not string match -q "$clean_pat" -- "$bname_no_ext"; and not string match -q "$flat_pat" -- "$bname"
                        continue
                    end
                end

                set -l dest_store ""
                if test $explicit_dir -eq 1
                    set dest_store "perm"
                else if test $explicit_dir -eq 2
                    set dest_store "tmp"
                else
                    if test "$store" = "perm"
                        set dest_store "tmp"
                    else
                        set dest_store "perm"
                    end
                end

                if test "$store" = "$dest_store"
                    continue
                end

                set -l dest_rel "$src_rel"
                if test -n "$out_pat"
                    set dest_rel (_kv_apply_out_pattern "$out_pat" "$src_rel" "$bname")
                end

                set -l dest_f ""
                set -l dest_manifest ""
                set -l src_manifest ""
                if test "$dest_store" = "perm"
                    set -l clean_d (string replace -r '^/+' '' -- "$dest_rel")
                    set dest_f "$base_dir/$clean_d"
                    set dest_manifest "$perm_manifest"
                    set src_manifest "$tmp_manifest"
                    set dest_rel "$clean_d"
                else
                    set -l flat_d (string replace -a '/' '_' -- (string replace -r '^/+' '' -- "$dest_rel"))
                    set dest_f "$tmp_dir/$flat_d"
                    set dest_manifest "$tmp_manifest"
                    set src_manifest "$perm_manifest"
                    set dest_rel "$flat_d"
                end

                mkdir -p (dirname "$dest_f")
                mv -f "$src_f" "$dest_f"
                if test -f "$src_f.meta"
                    mv -f "$src_f.meta" "$dest_f.meta"
                end

                _kv_unregister_snapshot "$src_manifest" "$src_f"
                _kv_register_snapshot "$dest_manifest" "$dest_f" "$dest_rel"
                _kv_update_alias_path "$alias_file" "$src_f" "$dest_f"

                if test "$store" = "perm"
                    find "$base_dir" -mindepth 1 -type d -empty -delete 2>/dev/null
                end

                echo "Migrated ($store -> $dest_store): $src_f -> $dest_f"
                set migrated_count (math $migrated_count + 1)
            end

            if test $migrated_count -eq 0
                echo "No tracked snapshots migrated."
            end

        case clear
            if test $erase_slot -eq 1
                curl -sf -X POST "$target_url/slots/$slot_id?action=erase" > /dev/null
                echo "Erased live slot $slot_id on $target_url"
            end

            if test (count $targets) -eq 0
                if test $use_tmp -eq 1
                    for entry in $tmp_entries
                        set -l f (string split -m 1 \t -- "$entry")[1]
                        rm -f "$f" "$f.meta"
                    end
                    : > "$tmp_manifest"
                    echo "Cleared tracked temp KV caches in $tmp_dir"
                end
                if test $use_perm -eq 1
                    for entry in $perm_entries
                        set -l f (string split -m 1 \t -- "$entry")[1]
                        rm -f "$f" "$f.meta"
                    end
                    find "$base_dir" -mindepth 1 -type d -empty -delete 2>/dev/null
                    : > "$perm_manifest"
                    : > "$alias_file"
                    echo "Cleared tracked permanent KV caches in $base_dir"
                end
            else
                for pat in $targets
                    set -l clean_pat (string replace -r '^/+' '' -- "$pat")
                    set -l flat_pat (string replace -a '/' '_' -- "$clean_pat")

                    if test -s "$alias_file"
                        set -l kept_aliases
                        while read -l a_name a_path
                            if test -z "$a_name"; or test -z "$a_path"
                                continue
                            end
                            if string match -q "$pat" -- "$a_name"
                                set -l in_perm (string match -q "$base_dir/*" -- "$a_path"; and echo 1; or echo 0)
                                set -l in_tmp (string match -q "$tmp_dir/*" -- "$a_path"; and echo 1; or echo 0)
                                if test \( $use_perm -eq 1 -a $in_perm -eq 1 \) -o \( $use_tmp -eq 1 -a $in_tmp -eq 1 \)
                                    if test -e "$a_path"
                                        rm -rf "$a_path" "$a_path.meta"
                                    end
                                    if test $in_perm -eq 1
                                        _kv_unregister_snapshot "$perm_manifest" "$a_path"
                                    end
                                    if test $in_tmp -eq 1
                                        _kv_unregister_snapshot "$tmp_manifest" "$a_path"
                                    end
                                    echo "Removed $a_path"
                                    continue
                                end
                            end
                            set -a kept_aliases "$a_name\t$a_path"
                        end < "$alias_file"
                        printf '%s\n' $kept_aliases > "$alias_file"
                    end

                    if test $use_tmp -eq 1
                        for entry in $tmp_entries
                            set -l f (string split -m 1 \t -- "$entry")[1]
                            set -l bname (basename "$f")
                            set -l bname_no_ext (string replace -r '\.bin$' '' -- "$bname")
                            if string match -q "$clean_pat" -- "$bname"; or string match -q "$clean_pat.bin" -- "$bname"; or string match -q "$clean_pat" -- "$bname_no_ext"; or string match -q "$flat_pat" -- "$bname"; or string match -q "$flat_pat.bin" -- "$bname"
                                rm -f "$f" "$f.meta"
                                _kv_unregister_snapshot "$tmp_manifest" "$f"
                                echo "Removed $f"
                            end
                        end
                    end

                    if test $use_perm -eq 1
                        for entry in $perm_entries
                            set -l cols (string split -m 2 \t -- "$entry")
                            set -l f $cols[1]
                            set -l rel $cols[2]
                            set -l rel_no_ext (string replace -r '\.bin$' '' -- "$rel")
                            set -l rel_dir (dirname "$rel")
                            set -l bname (basename "$f")
                            set -l bname_no_ext (string replace -r '\.bin$' '' -- "$bname")
                            if string match -q "$clean_pat" -- "$rel"; or string match -q "$clean_pat.bin" -- "$rel"; or string match -q "$clean_pat" -- "$rel_no_ext"; or string match -q "$clean_pat" -- "$rel_dir"; or string match -q "$clean_pat" -- "$bname"; or string match -q "$clean_pat" -- "$bname_no_ext"
                                rm -f "$f" "$f.meta"
                                _kv_unregister_snapshot "$perm_manifest" "$f"
                                echo "Removed $f"
                            end
                        end
                        find "$base_dir" -mindepth 1 -type d -empty -delete 2>/dev/null
                    end
                end
            end

        case '*'
            echo "Unknown subcommand: $subcmd (use 'save', 'load', 'list', 'clear', or 'migrate')" >&2
            return 1
    end
end
