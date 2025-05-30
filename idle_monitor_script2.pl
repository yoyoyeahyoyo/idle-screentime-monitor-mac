#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(strftime);
use Getopt::Long;

# Configuration
my $IDLE_THRESHOLD = 60;  # seconds to consider "idle"
my $CHECK_INTERVAL = 5;   # how often to check (seconds)
my $LOG_FILE = "activity_log.txt";
my $DEBUG_LOG_FILE = "debug_log.txt";
my $DEBUG_INTERVAL = 30;  # how often to log debug info (seconds)

# Command line options
my $debug_mode = 0;
my $help = 0;

GetOptions(
    'debug|d' => \$debug_mode,
    'help|h' => \$help,
    'idle-threshold=i' => \$IDLE_THRESHOLD,
    'check-interval=i' => \$CHECK_INTERVAL,
    'debug-interval=i' => \$DEBUG_INTERVAL,
) or die "Error in command line arguments\n";

if ($help) {
    print <<EOF;
Usage: $0 [options]

Options:
  -d, --debug              Enable debug logging to $DEBUG_LOG_FILE
  --idle-threshold N       Seconds before considering idle (default: $IDLE_THRESHOLD)
  --check-interval N       How often to check status in seconds (default: $CHECK_INTERVAL)
  --debug-interval N       How often to log debug info in seconds (default: $DEBUG_INTERVAL)
  -h, --help              Show this help message

Examples:
  $0                      # Normal monitoring
  $0 --debug              # Enable debug logging
  $0 --idle-threshold 120 # Consider idle after 2 minutes
EOF
    exit 0;
}

# Global variables
my $current_state = "unknown";  # "active", "idle", "display_sleep", "system_sleep"
my $state_start_time = time();
my $total_active_time = 0;
my $total_idle_time = 0;
my $total_display_sleep_time = 0;
my $total_system_sleep_time = 0;
my $last_known_idle_time = 0;
my $last_debug_log_time = 0;

# Detection result storage for display
my %detection_results = ();

# Time calculation functions
sub format_duration {
    my ($seconds) = @_;
    my $hours = int($seconds / 3600);
    my $minutes = int(($seconds % 3600) / 60);
    my $secs = $seconds % 60;
    return sprintf("%02d:%02d:%02d", $hours, $minutes, $secs);
}

sub get_timestamp {
    return strftime("%Y-%m-%d %H:%M:%S", localtime());
}

sub get_idle_time {
    my $idle_cmd = q{ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'};
    my $idle_time = `$idle_cmd`;
    chomp($idle_time);
    return $idle_time || 0;
}

sub detect_sleep_state {
    my %results = ();
    
    # Method 1: Check IODisplayWrangler power state
    my $wrangler_cmd = q{ioreg -r -c "IODisplayWrangler" | grep "CurrentPowerState" | head -1};
    my $wrangler_info = `$wrangler_cmd 2>/dev/null`;
    chomp($wrangler_info);
    $results{wrangler_raw} = $wrangler_info || "N/A";
    
    if ($wrangler_info =~ /CurrentPowerState.*=\s*(\d+)/) {
        $results{wrangler_state} = $1;
        $results{display_wrangler_sleep} = ($1 == 0) ? "YES" : "NO";
    } else {
        $results{wrangler_state} = "unknown";
        $results{display_wrangler_sleep} = "UNKNOWN";
    }
    
    # Method 2: Check AppleBacklightDisplay brightness
    my $brightness_cmd = q{ioreg -r -c "AppleBacklightDisplay" | grep '"brightness"' | head -1};
    my $brightness_info = `$brightness_cmd 2>/dev/null`;
    chomp($brightness_info);
    $results{brightness_raw} = $brightness_info || "N/A";
    
    if ($brightness_info =~ /"brightness".*=\s*(\d+)/) {
        $results{brightness_value} = $1;
        $results{brightness_available} = "YES";
    } else {
        $results{brightness_value} = "N/A";
        $results{brightness_available} = "NO";
    }
    
    # Method 3: Check system profiler display count
    my $display_cmd = q{system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution"};
    my $display_count = `$display_cmd`;
    chomp($display_count);
    $results{display_count} = $display_count || 0;
    $results{displays_detected} = ($display_count > 0) ? "YES" : "NO";
    
    # Method 4: Check idle time patterns
    my $current_idle = get_idle_time();
    my $idle_change = abs($current_idle - $last_known_idle_time);
    $results{idle_time} = $current_idle;
    $results{idle_change} = $idle_change;
    $results{idle_stuck} = ($current_idle > 300 && $idle_change < 2) ? "YES" : "NO";
    
    # Method 5: Check pmset system state
    my $pmset_cmd = q{pmset -g | head -5};
    my $pmset_info = `$pmset_cmd 2>/dev/null`;
    chomp($pmset_info);
    $results{pmset_info} = $pmset_info || "N/A";
    
    return %results;
}

sub determine_state {
    my %detect = detect_sleep_state();
    
    # Store results for display
    %detection_results = %detect;
    
    # Decision logic
    if ($detect{idle_stuck} eq "YES") {
        return "system_sleep";
    } elsif ($detect{display_wrangler_sleep} eq "YES" || 
             ($detect{brightness_available} eq "NO" && $detect{displays_detected} eq "NO")) {
        return "display_sleep";
    } elsif ($detect{idle_time} >= $IDLE_THRESHOLD) {
        return "idle";
    } else {
        return "active";
    }
}

sub log_debug_info {
    return unless $debug_mode;
    
    my $timestamp = get_timestamp();
    open(my $fh, '>>', $DEBUG_LOG_FILE) or die "Cannot open $DEBUG_LOG_FILE: $!";
    
    print $fh "\n$timestamp - DEBUG INFO\n";
    print $fh "=" x 50 . "\n";
    print $fh "Current State: $current_state\n";
    print $fh "Idle Time: $detection_results{idle_time}s\n";
    print $fh "Idle Change: $detection_results{idle_change}s\n";
    print $fh "Display Wrangler State: $detection_results{wrangler_state}\n";
    print $fh "Display Sleep (Wrangler): $detection_results{display_wrangler_sleep}\n";
    print $fh "Brightness Value: $detection_results{brightness_value}\n";
    print $fh "Brightness Available: $detection_results{brightness_available}\n";
    print $fh "Display Count: $detection_results{display_count}\n";
    print $fh "Displays Detected: $detection_results{displays_detected}\n";
    print $fh "Idle Stuck Pattern: $detection_results{idle_stuck}\n";
    print $fh "\nRaw Command Outputs:\n";
    print $fh "Wrangler: $detection_results{wrangler_raw}\n";
    print $fh "Brightness: $detection_results{brightness_raw}\n";
    print $fh "PMSet Info: $detection_results{pmset_info}\n";
    print $fh "=" x 50 . "\n";
    
    close($fh);
}

sub log_state_change {
    my ($old_state, $new_state, $duration) = @_;
    my $timestamp = get_timestamp();
    my $duration_str = format_duration($duration);
    
    open(my $fh, '>>', $LOG_FILE) or die "Cannot open $LOG_FILE: $!";
    print $fh "$timestamp - Changed from $old_state to $new_state (duration: $duration_str)\n";
    close($fh);
    
    print "\n$timestamp - $old_state -> $new_state ($duration_str)\n";
}

sub update_totals {
    my ($state, $duration) = @_;
    
    if ($state eq "active") {
        $total_active_time += $duration;
    } elsif ($state eq "idle") {
        $total_idle_time += $duration;
    } elsif ($state eq "display_sleep") {
        $total_display_sleep_time += $duration;
    } elsif ($state eq "system_sleep") {
        $total_system_sleep_time += $duration;
    }
}

sub print_summary {
    my $total_time = $total_active_time + $total_idle_time + $total_display_sleep_time + $total_system_sleep_time;
    
    print "\n" . "="x60 . "\n";
    print "SESSION SUMMARY\n";
    print "="x60 . "\n";
    print "Total Active Time:        " . format_duration($total_active_time) . "\n";
    print "Total Idle Time:          " . format_duration($total_idle_time) . "\n";
    print "Total Display Sleep Time: " . format_duration($total_display_sleep_time) . "\n";
    print "Total System Sleep Time:  " . format_duration($total_system_sleep_time) . "\n";
    print "Total Session Time:       " . format_duration($total_time) . "\n";
    
    if ($total_time > 0) {
        printf "Active Percentage:        %.1f%%\n", ($total_active_time / $total_time) * 100;
        printf "Idle Percentage:          %.1f%%\n", ($total_idle_time / $total_time) * 100;
        printf "Display Sleep Percentage: %.1f%%\n", ($total_display_sleep_time / $total_time) * 100;
        printf "System Sleep Percentage:  %.1f%%\n", ($total_system_sleep_time / $total_time) * 100;
    }
    print "="x60 . "\n";
}

sub get_state_display_name {
    my ($state) = @_;
    return {
        'active' => 'ACTIVE',
        'idle' => 'IDLE',
        'display_sleep' => 'DISPLAY_SLEEP',
        'system_sleep' => 'SYSTEM_SLEEP',
        'unknown' => 'UNKNOWN'
    }->{$state} || 'UNKNOWN';
}

sub cleanup_and_exit {
    my $current_time = time();
    my $duration = $current_time - $state_start_time;
    
    update_totals($current_state, $duration);
    log_state_change($current_state, "session_end", $duration);
    print_summary();
    
    # Log final summary to file
    open(my $fh, '>>', $LOG_FILE) or die "Cannot open $LOG_FILE: $!";
    print $fh "\n" . get_timestamp() . " - SESSION ENDED\n";
    print $fh "Active: " . format_duration($total_active_time) . 
              ", Idle: " . format_duration($total_idle_time) . 
              ", Display Sleep: " . format_duration($total_display_sleep_time) .
              ", System Sleep: " . format_duration($total_system_sleep_time) . "\n\n";
    close($fh);
    
    exit(0);
}

# Signal handlers
$SIG{INT} = \&cleanup_and_exit;
$SIG{TERM} = \&cleanup_and_exit;

# Main monitoring loop
print "Starting idle time monitor...\n";
print "Idle threshold: $IDLE_THRESHOLD seconds\n";
print "Check interval: $CHECK_INTERVAL seconds\n";
print "Activity log: $LOG_FILE\n";
if ($debug_mode) {
    print "Debug logging: ENABLED ($DEBUG_LOG_FILE, every ${DEBUG_INTERVAL}s)\n";
}
print "Press Ctrl+C to stop and see summary\n\n";

# Initialize log file
open(my $fh, '>>', $LOG_FILE) or die "Cannot open $LOG_FILE: $!";
print $fh get_timestamp() . " - SESSION STARTED" . ($debug_mode ? " (DEBUG MODE)" : "") . "\n";
close($fh);

while (1) {
    my $current_time = time();
    my $new_state = determine_state();
    
    # Log debug info periodically
    if ($debug_mode && ($current_time - $last_debug_log_time) >= $DEBUG_INTERVAL) {
        log_debug_info();
        $last_debug_log_time = $current_time;
    }
    
    # Detect state change
    if ($new_state ne $current_state && $current_state ne "unknown") {
        my $duration = $current_time - $state_start_time;
        update_totals($current_state, $duration);
        log_state_change($current_state, $new_state, $duration);
    }
    
    # Update state if changed
    if ($new_state ne $current_state) {
        $current_state = $new_state;
        $state_start_time = $current_time;
    }
    
    # Show current status with detection details
    my $state_display = get_state_display_name($current_state);
    
    # Calculate current totals including ongoing session
    my $current_session_duration = $current_time - $state_start_time;
    my $display_active = $total_active_time;
    my $display_idle = $total_idle_time;
    my $display_display_sleep = $total_display_sleep_time;
    my $display_system_sleep = $total_system_sleep_time;
    
    # Add current session time to appropriate counter
    if ($current_state eq "active") {
        $display_active += $current_session_duration;
    } elsif ($current_state eq "idle") {
        $display_idle += $current_session_duration;
    } elsif ($current_state eq "display_sleep") {
        $display_display_sleep += $current_session_duration;
    } elsif ($current_state eq "system_sleep") {
        $display_system_sleep += $current_session_duration;
    }
    
    # Clear the line and show current status
    print "\r" . " " x 120 . "\r";  # Clear previous line completely
    printf "%s - %s | idle:%ds | wrangler:%s | bright:%s | displays:%s | Active:%s Idle:%s DispSleep:%s SysSleep:%s", 
           get_timestamp(), 
           $state_display,
           $detection_results{idle_time} || 0,
           $detection_results{wrangler_state} || "?",
           $detection_results{brightness_value} || "?",
           $detection_results{display_count} || "?",
           format_duration($display_active),
           format_duration($display_idle),
           format_duration($display_display_sleep),
           format_duration($display_system_sleep);
    
    # Flush output to ensure immediate display
    STDOUT->flush();
    
    $last_known_idle_time = $detection_results{idle_time} || 0;
    sleep($CHECK_INTERVAL);
}