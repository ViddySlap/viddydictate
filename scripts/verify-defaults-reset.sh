# shellcheck shell=bash
# Sourced by scripts/verify.sh. Defines two functions and executes nothing at source time.
# The deterministic tier clears the test bundle's defaults domain before any gate, so a saved
# provider-onboarding flag in the user's real test domain cannot decide a gate's outcome.

# Print the test bundle's defaults domain. A throwaway selftest domain may be supplied through
# VD_RESET_DOMAIN_OVERRIDE for the python gate; any other value is refused with status 2.
vd_test_domain() {
    local d
    if [[ -n "${VD_RESET_DOMAIN_OVERRIDE:-}" ]]; then
        if [[ "$VD_RESET_DOMAIN_OVERRIDE" =~ ^com\.viddydictate\.app\.tests\.selftest\.[A-Za-z0-9-]+$ ]]; then
            printf '%s\n' "$VD_RESET_DOMAIN_OVERRIDE"
            return 0
        fi
        return 2
    fi
    # The sentinel stops command substitution from stripping the value's trailing whitespace;
    # then drop exactly the one record newline PlistBuddy appends. Anything left is refused.
    d="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Info-Tests.plist" 2>/dev/null; printf x)"
    d="${d%x}"
    d="${d%$'\n'}"
    [[ -n "$d" ]] || return 2
    [[ "$d" != *[[:space:]]* ]] || return 2
    [[ "$d" == *.tests ]] || return 2
    printf '%s\n' "$d"
    return 0
}

# Clear the test bundle's defaults domain. Refuse to touch the installed app's own domain or a
# domain that is empty or carries whitespace. Print exactly one reset line on success.
vd_reset_test_defaults() {
    local d installed existed
    d="$(vd_test_domain)" || return 2
    [[ -n "$d" ]] || return 2
    [[ "$d" != *[[:space:]]* ]] || return 2
    installed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Info.plist" 2>/dev/null; printf x)"
    installed="${installed%x}"
    installed="${installed%$'\n'}"
    [[ -n "$installed" ]] || return 2
    [[ "$installed" != *[[:space:]]* ]] || return 2
    [[ "$d" != "$installed" ]] || return 2
    if defaults read "$d" >/dev/null 2>&1; then
        existed=yes
    else
        existed=no
    fi
    defaults delete "$d" >/dev/null 2>&1 || true
    printf '[verify][deterministic] test-domain defaults reset: %s (existed: %s)\n' "$d" "$existed"
    return 0
}
