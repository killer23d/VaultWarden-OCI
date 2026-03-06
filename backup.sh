    # Fixed version for extracting mtime using epoch timestamp conversion
    # This ensures format string leaks are avoided across GNU/BSD systems.
    mtime=$(stat -c %Y "${backup}") || mtime=$(stat -f %m "${backup}")
