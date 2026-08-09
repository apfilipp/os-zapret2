{#
    Copyright (C) 2026 Umur Gorur
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice,
       this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
    AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
    OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
#}

<script>
    $(document).ready(function() {
        var blockcheckPollTimer = null;

        function blockcheckEscape(value) {
            if (value === undefined || value === null) {
                value = "";
            }
            return $("<div>").text(String(value)).html();
        }

        function blockcheckDuration(seconds) {
            seconds = parseInt(seconds || 0, 10);

            var minutes = Math.floor(seconds / 60);
            var remain = seconds % 60;

            if (minutes > 0) {
                return minutes + "m " + remain + "s";
            }

            return remain + "s";
        }

        function stopBlockcheckPolling() {
            if (blockcheckPollTimer !== null) {
                clearTimeout(blockcheckPollTimer);
                blockcheckPollTimer = null;
            }
        }

        function scheduleBlockcheckPoll(delay) {
            stopBlockcheckPolling();

            blockcheckPollTimer = setTimeout(function() {
                pollBlockcheck();
            }, delay);
        }

        function renderRunningBlockcheck(data) {
            $("#blockcheckBtn").prop("disabled", true);
            $("#blockcheckBtn_progress").addClass("fa fa-spinner fa-pulse");
			
			$("#blockcheckStopBtn_progress").removeClass("fa fa-spinner fa-pulse");
			$("#blockcheckStopBtn").prop("disabled", false).show();


            var html = "";

            html += '<strong>Blockcheck running</strong>';
            html += '<br>Domain: <strong>' + blockcheckEscape(data.domain) + '</strong>';
            html += '<br>Elapsed: ' + blockcheckEscape(blockcheckDuration(data.elapsed_seconds));
            html += '<br>Strategies tested: ' + blockcheckEscape(data.attempts);

            if (data.stage) {
                html += '<br><br><strong>Current test:</strong>';
                html += '<br><code style="white-space:normal;">' +
                    blockcheckEscape(data.stage) +
                    '</code>';
            }

            if (data.log_file) {
                html += '<br><br><small class="text-muted">Full log: <code>' +
                    blockcheckEscape(data.log_file) +
                    '</code></small>';
            }

            $("#blockcheckSummary").html(html);

            var winnersHtml = "";

            if (data.winners && data.winners.length > 0) {
                winnersHtml += '<strong>Working strategies found:</strong>';

                $.each(data.winners, function(index, winner) {
                    winnersHtml += '<div class="alert alert-success" style="margin-top:8px;margin-bottom:0;">';

                    if (winner.test) {
                        winnersHtml += '<strong>' +
                            blockcheckEscape(winner.test) +
                            '</strong>';

                        if (winner.ip_version) {
                            winnersHtml += ' / IPv' +
                                blockcheckEscape(winner.ip_version);
                        }

                        winnersHtml += '<br>';
                    }

                    if (winner.daemon) {
                        winnersHtml += '<small>' +
                            blockcheckEscape(winner.daemon) +
                            '</small><br>';
                    }

                    if (winner.strategy) {
                        winnersHtml += '<code style="white-space:normal;">' +
                            blockcheckEscape(winner.strategy) +
                            '</code>';
                    } else if (winner.raw) {
                        winnersHtml += '<code style="white-space:normal;">' +
                            blockcheckEscape(winner.raw) +
                            '</code>';
                    }

                    winnersHtml += '</div>';
                });
            } else {
                winnersHtml = '<em>No working strategies found yet.</em>';
            }

            var $winning = $("#blockcheckWinning");

			if ($winning.data("renderedHtml") !== winnersHtml) {
				$winning.html(winnersHtml);
				$winning.data("renderedHtml", winnersHtml);
			}

            if (data.tail) {
                $("#blockcheckRaw").text(data.tail);
            }

            scheduleBlockcheckPoll(2000);
        }

		function renderStoppedBlockcheck(data) {
			stopBlockcheckPolling();
		
			$("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");
			$("#blockcheckBtn").prop("disabled", false);
		
			$("#blockcheckStopBtn_progress").removeClass("fa fa-spinner fa-pulse");
			$("#blockcheckStopBtn").prop("disabled", false).hide();
		
			var html = '<span class="text-warning"><strong>Blockcheck stopped</strong></span>';
		
			if (data.domain) {
				html += '<br>Domain: <strong>' +
					blockcheckEscape(data.domain) +
					'</strong>';
			}
		
			if (data.elapsed_seconds !== undefined) {
				html += '<br>Elapsed: ' +
					blockcheckEscape(blockcheckDuration(data.elapsed_seconds));
			}
		
			if (data.log_file) {
				html += '<br><small class="text-muted">Full log: <code>' +
					blockcheckEscape(data.log_file) +
					'</code></small>';
			}
		
			$("#blockcheckSummary").html(html);
		}

        function renderFinishedBlockcheck(data) {
            stopBlockcheckPolling();

            $("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");
            $("#blockcheckBtn").prop("disabled", false);

            $("#blockcheckStopBtn_progress").removeClass("fa fa-spinner fa-pulse");
            $("#blockcheckStopBtn").prop("disabled", false).hide();

            var result = data.result || {};
            var duration = result.duration_seconds;

            if (duration === undefined || duration === null) {
                duration = data.elapsed_seconds;
            }

            var timingHtml = '';

            if (duration !== undefined && duration !== null) {
                timingHtml =
                    ' <small class="text-muted">(took ' +
                    blockcheckEscape(blockcheckDuration(duration)) +
                    ')</small>';
            }

            var logFileHtml = '';

            if (result.log_file) {
                logFileHtml =
                    '<br><small class="text-muted">Full log: <code>' +
                    blockcheckEscape(result.log_file) +
                    '</code></small>';
            }

            if (result.status !== "ok") {
                $("#blockcheckSummary").html(
                    '<span class="text-danger"><strong>Blockcheck failed</strong></span>' +
                    timingHtml +
                    '<br>' +
                    blockcheckEscape(result.message || "Unknown error") +
                    logFileHtml
                );

                $("#blockcheckWinning").empty().removeData("renderedHtml");

                if (result.log) {
                    $("#blockcheckRaw").text(result.log);
                }

                return;
            }

            var winning = (result.winning || []).filter(function(line) {
                return String(line).trim() !== '';
            });

            var allBaseline =
                winning.length > 0 &&
                winning.every(function(line) {
                    return /working without bypass/i.test(line);
                });

            var domain = result.domain || data.domain || "";
            var summaryHtml = "";

            if (allBaseline) {
                summaryHtml =
                    '<span class="text-success"><strong>' +
                    blockcheckEscape(domain) +
                    '</strong> reaches its server without DPI bypass.</span>' +
                    timingHtml +
                    '<br>The tested connection already works without a bypass strategy.' +
                    logFileHtml;
            } else {
                summaryHtml =
                    '<span class="text-success"><strong>Blockcheck finished</strong></span>' +
                    timingHtml;

                if (domain) {
                    summaryHtml +=
                        '<br>Domain: <strong>' +
                        blockcheckEscape(domain) +
                        '</strong>';
                }

                if (result.partial) {
                    summaryHtml +=
                        ' <span class="label label-warning">partial</span>' +
                        '<br><small class="text-muted">' +
                        'The scan did not complete, but strategies confirmed before termination are shown below.' +
                        '</small>';
                }

                summaryHtml += logFileHtml;
            }

            $("#blockcheckSummary").html(summaryHtml);

            var winnersHtml = "";

            if (winning.length > 0) {
                winnersHtml = '<strong>Working strategies:</strong>';
                winnersHtml += '<ul style="font-family:monospace;font-size:12px;margin-top:8px;">';

                $.each(winning, function(index, strategy) {
                    winnersHtml +=
                        '<li style="margin-bottom:6px;">' +
                        blockcheckEscape(strategy) +
                        '</li>';
                });

                winnersHtml += '</ul>';
            } else {
                winnersHtml =
                    '<em>No working strategies found in the standard test set.</em>';
            }

            $("#blockcheckWinning").html(winnersHtml);
            $("#blockcheckRaw").text(result.summary || result.log || '');
        }

		function renderStoppedBlockcheck(data) {
			stopBlockcheckPolling();

            $("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");
            $("#blockcheckBtn").prop("disabled", false);

            $("#blockcheckStopBtn_progress").removeClass("fa fa-spinner fa-pulse");
            $("#blockcheckStopBtn").prop("disabled", false).hide();

            var html = '<span class="text-warning"><strong>Blockcheck stopped</strong></span>';

            if (data.domain) {
                html += '<br>Domain: <strong>' +
                    blockcheckEscape(data.domain) +
                    '</strong>';
            }

            if (data.elapsed_seconds !== undefined) {
                html += '<br>Elapsed: ' +
                    blockcheckEscape(blockcheckDuration(data.elapsed_seconds));
            }

            if (data.log_file) {
                html += '<br><small class="text-muted">Full log: <code>' +
                    blockcheckEscape(data.log_file) +
                    '</code></small>';
            }

            $("#blockcheckSummary").html(html);
        }

        function renderBlockcheckStatus(data) {
            if (!data) {
                return;
            }

            if (data.status !== "ok") {
                stopBlockcheckPolling();

                $("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");
                $("#blockcheckBtn").prop("disabled", false);

				$("#blockcheckStopBtn_progress").removeClass("fa fa-spinner fa-pulse");
				$("#blockcheckStopBtn").prop("disabled", false).hide();

				$("#blockcheckSummary").html(
                    '<span class="text-danger">' +
                    blockcheckEscape(data.message || "Blockcheck status error") +
                    '</span>'
                );

                return;
            }

            if (data.state === "running") {
                renderRunningBlockcheck(data);
                return;
            }

            if (data.state === "finished") {
                renderFinishedBlockcheck(data);
                return;
            }

            if (data.state === "stopped") {
				renderStoppedBlockcheck(data);
				return;
			}

            if (data.state === "idle") {
                stopBlockcheckPolling();
                $("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");
                $("#blockcheckBtn").prop("disabled", false);
            
				$("#blockcheckStopBtn_progress").removeClass("fa fa-spinner fa-pulse");
				$("#blockcheckStopBtn").prop("disabled", false).hide();
			}
        }

        function pollBlockcheck() {
            $.ajax({
                type: "GET",
                url: "/api/zapret/diagnostics/blockcheckstatus",
                dataType: "json",
                timeout: 10000,

                success: function(data) {
                    renderBlockcheckStatus(data);
                },

                error: function() {
                    scheduleBlockcheckPoll(3000);
                }
            });
        }

        function resumeRunningBlockcheck() {
            $.ajax({
                type: "GET",
                url: "/api/zapret/diagnostics/blockcheckstatus",
                dataType: "json",
                timeout: 10000,

                success: function(data) {
                    if (data && data.status === "ok" && data.state === "running") {
                        renderRunningBlockcheck(data);
                    }
                }
            });
        }

        // ---- Test Domain Connectivity ----
        $("#testDomainBtn").click(function() {
            var domain = $("#testDomainInput").val().trim();

            if (!domain) {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_WARNING,
                    title: '{{ lang._("Warning") }}',
                    message: '{{ lang._("Please enter a domain name.") }}'
                });
                return;
            }

            $("#testDomainBtn_progress").addClass("fa fa-spinner fa-pulse");
            $("#testDomainResult").text("Testing...");

            ajaxCall(
                '/api/zapret/diagnostics/testdomain',
                {'domain': domain},
                function(data, status) {
                    $("#testDomainBtn_progress").removeClass("fa fa-spinner fa-pulse");

                    if (data.status === 'ok') {
                        $("#testDomainResult").text(data.result);
                    } else {
                        $("#testDomainResult").text(
                            "Error: " + (data.message || "Unknown error")
                        );
                    }
                }
            );
        });

        // ---- Blockcheck (Strategy Finder) ----
        $("#blockcheckBtn").click(function() {
            var domain = $("#blockcheckDomainInput").val().trim();
			var mode = $("#blockcheckMode").val();
            if (!domain) {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_WARNING,
                    title: '{{ lang._("Warning") }}',
                    message: '{{ lang._("Please enter a blocked domain name.") }}'
                });
                return;
            }

            stopBlockcheckPolling();

            $("#blockcheckBtn").prop("disabled", true);
            $("#blockcheckBtn_progress").addClass("fa fa-spinner fa-pulse");
            $("#blockcheckSummary").html(
                '<em>Starting blockcheck against <strong>' +
                blockcheckEscape(domain) +
                '</strong>...</em>'
            );
            $("#blockcheckWinning").empty().removeData("renderedHtml");
			$("#blockcheckRaw").text('');

            $.ajax({
                type: "POST",
                url: "/api/zapret/diagnostics/blockcheck",
                data: {
					'domain': domain,
					'mode': mode
				},
                dataType: "json",
                timeout: 10000,

                success: function(data) {
                    if (data && data.status === "ok") {
                        pollBlockcheck();
                        return;
                    }

                    $("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");
                    $("#blockcheckBtn").prop("disabled", false);

                    $("#blockcheckSummary").html(
                        '<span class="text-danger">' +
                        blockcheckEscape(
                            (data && data.message) ||
                            "Unable to start blockcheck"
                        ) +
                        '</span>'
                    );
                },

                error: function(jqXHR, textStatus) {
                    $("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");
                    $("#blockcheckBtn").prop("disabled", false);

                    $("#blockcheckSummary").html(
                        '<span class="text-danger">Request failed: ' +
                        blockcheckEscape(textStatus) +
                        '</span>'
                    );
                }
            });
        });

        $("#blockcheckStopBtn").click(function() {
            $("#blockcheckStopBtn").prop("disabled", true);
            $("#blockcheckStopBtn_progress").addClass("fa fa-spinner fa-pulse");

            $("#blockcheckSummary").append(
                '<br><em>Stopping blockcheck...</em>'
            );

            $.ajax({
                type: "POST",
                url: "/api/zapret/diagnostics/blockcheckstop",
                dataType: "json",
                timeout: 10000,

                success: function(data) {
                    if (data && data.status === "ok") {
                        scheduleBlockcheckPoll(500);
                        return;
                    }

                    $("#blockcheckStopBtn_progress").removeClass("fa fa-spinner fa-pulse");
                    $("#blockcheckStopBtn").prop("disabled", false);

                    $("#blockcheckSummary").append(
                        '<br><span class="text-danger">' +
                        blockcheckEscape(
                            (data && data.message) || "Unable to stop blockcheck"
                        ) +
                        '</span>'
                    );
                },

                error: function(jqXHR, textStatus) {
                    $("#blockcheckStopBtn_progress").removeClass("fa fa-spinner fa-pulse");
                    $("#blockcheckStopBtn").prop("disabled", false);

                    $("#blockcheckSummary").append(
                        '<br><span class="text-danger">Stop request failed: ' +
                        blockcheckEscape(textStatus) +
                        '</span>'
                    );
                }
            });
        });

        // If the page was refreshed while a detached blockcheck is still
        // running, reconnect the UI to it automatically.
        resumeRunningBlockcheck();
    });
</script>

<section class="page-content-main">
    <div class="container-fluid">

        <div class="row">
            <section class="col-xs-12">
                <div class="content-box">

                    <div class="content-box-header">
                        <h3>{{ lang._('Test Domain Connectivity') }}</h3>
                    </div>

                    <div class="content-box-main">

                        <div class="table-responsive">
                            <table class="table table-striped">
                                <tbody>
                                    <tr>
                                        <td style="width: 200px;">
                                            {{ lang._('Domain') }}
                                        </td>

                                        <td>
                                            <input
                                                type="text"
                                                class="form-control"
                                                id="testDomainInput"
                                                placeholder="example.com"
                                            />
                                        </td>

                                        <td style="width: 150px;">
                                            <button
                                                class="btn btn-primary"
                                                id="testDomainBtn"
                                                type="button"
                                            >
                                                {{ lang._('Test') }}
                                                <i id="testDomainBtn_progress"></i>
                                            </button>
                                        </td>
                                    </tr>
                                </tbody>
                            </table>
                        </div>

                        <div class="col-md-12">
                            <pre
                                id="testDomainResult"
                                style="max-height: 300px; overflow-y: auto; white-space: pre-wrap;"
                            >{{ lang._('Enter a domain and click Test to check HTTPS connectivity.') }}</pre>
                        </div>

                    </div>
                </div>
            </section>
        </div>

        <div class="row">
            <section class="col-xs-12">
                <div class="content-box">

                    <div class="content-box-header">
                        <h3>{{ lang._('Blockcheck (Strategy Finder)') }}</h3>
                    </div>

                    <div class="content-box-main">

                        <div class="table-responsive">
                            <table class="table table-striped">
                                <tbody>
                                    <tr>
                                        <td style="width: 200px;">
                                            {{ lang._('Blocked Domain') }}
                                        </td>

                                        <td>
                                            <input
                                                type="text"
                                                class="form-control"
                                                id="blockcheckDomainInput"
                                                placeholder="rutracker.org"
                                            />
											<div style="margin-top: 8px;">
												<select class="form-control" id="blockcheckMode">
													<option value="tls13" selected>TLS 1.3 (HTTPS / TCP 443)</option>
													<option value="tls12">TLS 1.2 (HTTPS / TCP 443)</option>
													<option value="http3">HTTP/3 (QUIC / UDP 443)</option>
													<option value="http">HTTP (TCP 80)</option>
													<option value="all">All protocols</option>
												</select>
											</div>
                                        </td>

                                        <td style="width: 220px;">
											<button
												class="btn btn-primary"
												id="blockcheckBtn"
												type="button"
											>
												{{ lang._('Run') }}
												<i id="blockcheckBtn_progress"></i>
											</button>
										
											<button
												class="btn btn-danger"
												id="blockcheckStopBtn"
												type="button"
												style="display:none; margin-left:5px;"
											>
												{{ lang._('Stop') }}
												<i id="blockcheckStopBtn_progress"></i>
											</button>
										</td>
                                    </tr>
                                </tbody>
                            </table>
                        </div>

                        <div class="col-md-12" style="padding-top: 10px;">

                            <div id="blockcheckSummary">
                                {{ lang._('Enter a domain that your ISP currently blocks and click Run. Blockcheck runs in the background and live progress will be shown here.') }}
                            </div>

                            <div
                                id="blockcheckWinning"
                                style="padding-top: 10px;"
                            ></div>

                            <details style="padding-top: 10px;">
                                <summary>
                                    {{ lang._('Live output / full output (advanced)') }}
                                </summary>

                                <pre
                                    id="blockcheckRaw"
                                    style="max-height: 400px; overflow-y: auto; white-space: pre-wrap; font-size: 11px;"
                                ></pre>
                            </details>
                        </div>
                    </div>
                </div>
            </section>
        </div>
    </div>
</section>
