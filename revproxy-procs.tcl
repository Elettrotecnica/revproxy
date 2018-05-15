package require nsf

#
# This file can be installed e.g. as a tcl module in /ns/tcl/revproxy/revproxy-procs.tcl
# and registered as a tcl module in the config file.
#

namespace eval ::revproxy {

    set version 0.10
    set verbose 0

    #
    # Upstream handler (deliver request from an upstream server)
    #
    # Serve the requested file from an upstream server, which might be
    # an http or https server. NaviServer acts as a reverse proxy
    # server.  The upstream function works incrementally and functions
    # as well for WebSockets (including secure WebSockets).  Note that
    # we can specify for every filter registration different parameters
    # (e.g. different timeouts).
    #

    nsf::proc upstream {
        what
        -target
        {-timeout 10.0}
        {-validation_callback ""}
        {-regsubs:0..n ""}
        {-exception_callback "::revproxy::exception"}
        {-url_rewrite_callback "::revproxy::rewrite_url"}
        {-backend_reply_callback ""}
    } {
        #
        # Assemble URL in two steps:
        #   - First, perform regsubs on the URL (if provided)
        #   - Second, compose the final upstream URL via the default
        #     handler or a custom callback
        #
        set url [ns_conn url]
        if {[llength $regsubs] > 0} {
            #
            # When "regsubs" is provided, it has to be a list of pairs
            # with two elements, the "from" regexp and the "to"
            # substitution pattern. By providing a list of regsubs,
            # multiple substitutions can be performed.
            #
            foreach regsub $regsubs {
                lassign $regsub from to
                #log notice "regsub $from $url $to url"
                regsub $from $url $to url
            }
        }

        #
        # Compute the final upstream URL
        #
        set url [{*}$url_rewrite_callback \
                     -target $target \
                     -url $url \
                     -query [ns_conn query]]

        #
        # Get header fields from request, add X-Forwarded-For.
        #
        # We might update/add more headers fields here
        #
        set queryHeaders [ns_conn headers]
        ns_set update $queryHeaders X-Forwarded-For [ns_conn peeraddr]

        #
        # Inject a "connection close" instruction to avoid persistent
        # connections to the backend. Otherwise we would not be able
        # to use the registration url (the url passed to
        # ns_register_filter) for rewriting incoming requests, since
        # the client sends for persistent connections the request
        # unmodified sent via the already open channel.
        #
        # We might have to take precautions for WebSockets here.
        #
        ns_set update $queryHeaders Connection close

        #ns_log notice queryHeaders=[ns_set array $queryHeaders]

        if {$validation_callback ne ""} {
            {*}$validation_callback -url $url
        }

        if {[catch {
            #
            # Open backend channel, get frontend channel and connect these.
            #
            set backendChan [ns_connchan open \
                                 -method [ns_conn method] \
                                 -headers $queryHeaders \
                                 -timeout $timeout \
                                 -version [ns_conn version] \
                                 $url]
            #
            # Check, if we have requests with a body
            #
            set contentLength [ns_set iget $queryHeaders content-length {}]
            if {$contentLength ne ""} {
                set contentfile [ns_conn contentfile]
                set chunk 16000
                if {$contentfile eq ""} {
                    #
                    # string content
                    #
                    set data [ns_conn content -binary]
                    set length [string length $data]
                    set i 0
                    set j [expr {$chunk -1}]
                    while {$i < $length} {
                        log notice "upstream: send max $chunk bytes from string to $backendChan (length $contentLength)"
                        ns_connchan write $backendChan [string range $data $i $j]
                        incr i $chunk
                        incr j $chunk
                    }
                } else {
                    #
                    # file content
                    #
                    set F [open $contentfile r]
                    fconfigure $F -encoding binary -translation binary
                    while {1} {
                        log notice "upstream: send max $chunk bytes from file to $backendChan (length $contentLength)"
                        ns_connchan write $backendChan [read $F $chunk]
                        if {[eof $F]} break
                    }
                    close $F
                }
            }
            #
            # Full request was received and transmitted upstream, now handle replies
            #
            set frontendChan [ns_connchan detach]
            log notice "back $backendChan front $frontendChan method [ns_conn method] version 1.0 $url"

            ns_connchan callback -timeout $timeout $frontendChan \
                [list ::revproxy::spool $frontendChan $backendChan client  $timeout 0] rex
            ns_connchan callback -timeout $timeout $backendChan  \
                [list ::revproxy::backendReply -callback $backend_reply_callback $backendChan $frontendChan $url $timeout 0] rex

        } errorMsg]} {
            ns_log error "revproxy::upstream: error during establishing connections to $url: $errorMsg"
            if {$exception_callback ne ""} {
                {*}$exception_callback -error $errorMsg -url $url
            }
            foreach chan {frontendChan backendChan} {
                if {[info exists $chan]} {
                    ns_connchan close [set $chan]
                }
            }
        }
        return filter_return
    }

    nsf::proc gateway_timeout { from msg } {
        log notice $msg
        #
        # We received a timeout and we might send a "504 Gateway
        # Timeout" to the client. However, this can be only done, when
        # on the outgoing channel no data was sent so far. If the
        # timeout occurs in the middle of the datastream, the timeout
        # will be logged and the connection terminated (by the
        # caller).
        #
        foreach entry [ns_connchan list] {
            if {[lindex $entry 0] eq $from} {
                lassign $entry . . . . . sent received .
                #log notice "FROM channel <$entry> sent $sent reveived $received"
                if {$sent == 0} {
                    ns_connchan write $from "HTTP/1.0 504 Gateway Timeout\r\n\r\n"
                }
            }
        }
    }

    #
    # Spool data from $from to $to. The arguments "url" and "arg" might
    # be used for debugging, "condition" is the one-character reason code
    # for calling this function.
    #
    # When this function returns 0, this channel end will be
    # automatically closed.
    #
    nsf::proc spool { from to url arg timeout condition } {
        log notice "spool from $from ([ns_connchan exists $from]) to $to ([ns_connchan exists $to]): $condition"

        if {$condition eq "t"} {
            ::revproxy::gateway_timeout $from "timeout occurred while spooling $from to $to"
        } elseif {$condition ne "r"} {
            log notice "unexpected condition $condition while spooling $from to $to"
        }

        if {[ns_connchan exists $from]} {
            set msg [ns_connchan read $from]
            if {$msg eq ""} {
                log notice "... auto closing $from manual $to: $url "
                #
                # Close our end ...
                #
                set result 0
                #
                # ... and close as well the other end.
                #
                if {[ns_connchan exists $to]} {
                    ns_connchan close $to
                }
            } else {
                log notice "spool: send [string length $msg] bytes from $from to $to ($url)"

                if {[catch {ns_connchan write $to $msg} errorMsg]} {
                    #
                    # A "broken pipe" erro might happen easily, when
                    # the transfer is aborted by the client. Do't
                    # complain about it.
                    #
                    if {![string match "*Broken pipe*" $errorMsg]} {
                        ns_log error $errorMsg
                    }
                }
                # record $to $msg
                set result 1
            }
        } else {
            log notice "... called on closed channel $from reason $condition"
            set result 0
        }

        # log notice "... return $result"
        return $result
    }

    #
    # Handle backend replies in order to be able to post-process the
    # reply header fields. This is e.g. necessary to downgrade to
    # HTTP/1.0 requests.
    #
    nsf::proc backendReply { {-callback ""} from to url timeout arg condition } {

        if { $condition eq "r" } {
            #
            # Read from backend
            #
            set msg [ns_connchan read $from]

        } elseif { $condition eq "t" } {
            #
            # Timeout
            #
            ::revproxy::gateway_timeout $to "timeout occurred while waiting for backend reply $from to $to"
            set msg ""

        } else {
            log notice "unexpected condition $condition while processing backend reply"
            set msg ""
        }

        if {$msg eq ""} {
            log notice "backendReply: ... auto closing $from $url"
            #
            # Close our end ...
            #
            set result 0
            #
            # ... and close as well the other end.
            #
            ns_connchan close $to
        } else {
            #
            # Receive reply from backend. We assume, that we can
            # receive the header of the reply in one sweep, ... which
            # seems to be the case on our tested systems.
            #
            log notice "backendReply: send [string length $msg] bytes from $from to $to ($url)"
            #record $to $msg

            if {[regexp {^([^\n]+)\r\n(.*?)\r\n\r\n(.*)$} $msg . first header body]} {
                log notice "backendReply: first <$first> HEAD <$header>"
                set status [lindex $first 1]
                #
                # For most error codes, we want to make sure that the
                # connection is closed after every request. This is
                # currently necessary, since for persistent
                # connections, we can't substitute the request URL
                # inside the stream without continuous parsing.
                #
                # For informational status codes (1xx) there is no
                # need to close the connection (e.g. WebSockets).
                #
                if {$status >= 200} {
                    #
                    # Parse the header lines line by line. The current
                    # code is slightly over-optimistic, since it does
                    # not handle request header continuation lines.
                    #
                    set replyHeaders [ns_set create]
                    foreach line [split $header \n] {
                        set line [string trimright $line \r]
                        #log notice "backendReply: [list ns_parseheader $replyHeaders $line]"
                        ns_parseheader $replyHeaders $line preserve
                    }

                    #
                    # In case, a backendReplyCallback is set, call it
                    # with "-status" and "-replyHeaders". The callback
                    # can modify the ns_set with the reply headers,
                    # maybe, stripping upstream headers etc.
                    #
                    if {$callback ne ""} {
                        {*}$callback -url $url -replyHeaders $replyHeaders -status $status
                    }

                    #
                    # Make sure to close the connection
                    #
                    ns_set idelkey $replyHeaders connection
                    ns_set put $replyHeaders Connection close

                    #
                    # Build the reply
                    #
                    set reply $first\r\n
                    set size [ns_set size $replyHeaders]
                    for {set i 0} {$i < $size} {incr i} {
                        append reply "[ns_set key $replyHeaders $i]: [ns_set value $replyHeaders $i]\r\n"
                    }
                    log notice "backendReply: <$reply>"
                    append reply \r\n$body
                    ns_connchan write $to $reply
                    #record $to-rewritten $reply

                } else {
                    #
                    # e.g. HTTP/1.1 101 Switching Protocols
                    #
                    ns_connchan write $to $msg
                }
                #
                # Change the callback to regular spooling for the
                # future requests.
                #
                ns_connchan callback -timeout $timeout $from [list ::revproxy::spool $from $to $url $timeout 0] rex
                set result 1
            } else {
                log notice "backendReply: could not parse header <$msg>"
                set result 0
            }
        }

        # log notice "... return $result"
        return $result
    }

    #
    # Default exception handler for reporting error messages to the
    # browser.
    #
    nsf::proc exception { -error -url } {
        ns_returnerror 503 \
            "Error during opening connection to backend [ns_quotehtml $url] failed. \
         <br>Error message: [ns_quotehtml $error]"
    }

    #
    # Default rewrite_url handler for composing upstream target URL
    # based on the target (containing at typically the protocol and
    # location), the incoming URL and the actual query parameter form
    # the incoming URL.
    #
    nsf::proc rewrite_url { -target -url {-query ""}} {
        set url $target$url
        if {$query ne ""} {append url ?$query}
        return $url
    }


    #
    # Simple logger for error log, evaluating the ::revproxy::verbose
    # variable.
    #
    nsf::proc log {severity msg} {
        if {$::revproxy::verbose} {
            ns_log $severity "PROXY: $msg"
        }
    }

    #
    # Simple recorder for writing content to a file (for
    # debugging). The files are saved in the tmp directory, under a
    # folder named by the PID, channel identifier are used as file
    # names.
    #
    nsf::proc record {chan msg} {
        file mkdir [ns_config ns/parameters tmpdir]/[ns_info pid]
        set fn [ns_config ns/parameters tmpdir]/[ns_info pid]/$chan
        set F [open $fn a]
        puts -nonewline $F $msg
        close $F
    }

    #
    # Get configured urls
    #
    set filters [ns_config ns/server/[ns_info server]/module/revproxy filters]
    if {$filters ne ""} {
        ns_log notice "==== revproxy registers filters\n$filters"
        eval $filters
    }

    ns_log notice "revproxy module version $version loaded"
}

#
# Local variables:
#    mode: tcl
#    tcl-indent-level: 4
#    indent-tabs-mode: nil
# End:
