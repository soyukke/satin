fn admit_control_client(control: &mut TmuxControl) {
    control.feed(b"%begin 9 1 0\n%end 9 1 0\n").unwrap();
    assert_eq!(
        control.take_outgoing().unwrap(),
        format!("{}\n", admission::CONTROL_CLIENT_CHECK_COMMAND).as_bytes()
    );
    control.feed(b"%begin 9 2 0\n1\n%end 9 2 0\n").unwrap();
    assert_eq!(
        control.take_outgoing().unwrap(),
        b"refresh-client -f pause-after=5 -B 'satin-pane-title:%*:#{q:pane_title}' \
          -B 'satin-session-clients::#{session_attached_list}'\n"
    );
    control.feed(b"%begin 9 3 0\n%end 9 3 0\n").unwrap();
}

#[test]
fn keeps_passthrough_protocols_while_a_pane_is_rehydrating() {
    let mut control = TmuxControl {
        rehydrating_panes: [7].into(),
        ..Default::default()
    };
    control.push_output(
        7,
        b"duplicate text\x1bPtmux;\x1b\x1b_Ga=T,i=7;AAAA\x1b\x1b\\\x1b\\".to_vec(),
    );
    assert_eq!(control.take_event(), None);
    control.rehydrating_panes.remove(&7);
    control.flush_rehydration_passthrough(7);
    assert_eq!(
        control.take_event(),
        Some(TmuxControlEvent::PaneOutput {
            pane_id: 7,
            data: b"\x1b_Ga=T,i=7;AAAA\x1b\\".to_vec(),
        })
    );
}

#[test]
fn session_notification_requests_and_parses_topology() {
    let mut control = TmuxControl::default();
    control
        .feed(b"\x1bP1000p%session-changed $0 satin\n")
        .unwrap();
    assert!(control.take_outgoing().is_none());
    admit_control_client(&mut control);
    let command = control.take_outgoing().unwrap();
    assert!(
        String::from_utf8(command)
            .unwrap()
            .starts_with("list-panes -s")
    );
    let row = snapshot_row("/tmp", 20, false, false);
    control
        .feed(format!("%begin 1 2 0\n{row}\n%end 1 2 0\n").as_bytes())
        .unwrap();
    let event = control.events.back().unwrap();
    let TmuxControlEvent::Snapshot { snapshot } = event else {
        panic!("expected snapshot");
    };
    assert_eq!(snapshot.session_name, "satin");
    assert_eq!(snapshot.socket_path, "/tmp/tmux.sock");
    assert_eq!(snapshot.windows[0].active_pane_id, 7);
    assert_eq!(snapshot.windows[0].panes[0].cursor_x, 18);
    assert_eq!(snapshot.windows[0].panes[0].cursor_y, 4);
    assert!(snapshot.windows[0].panes[0].cursor_visible);
    assert_eq!(snapshot.windows[0].panes[0].history_size, 20);
    assert_eq!(snapshot.windows[0].panes[0].private_modes, [7, 1004]);
    assert_eq!(snapshot.windows[0].panes[0].key_mode, "VT10x");
    assert_eq!(snapshot.windows[0].panes[0].current_command, "zsh");
    assert_eq!(snapshot.windows[0].panes[0].title, "⠹ satin");
    assert_eq!(snapshot.windows[0].panes[0].allow_passthrough, "off");
    assert!(!snapshot.windows[0].zoomed);
    acknowledge_passthrough_setup(&mut control, "1 3 0");
    assert_eq!(
        control.take_outgoing().unwrap(),
        b"capture-pane -p -e -C -S -20 -t %7\n"
    );
}

#[test]
fn pane_title_subscription_refreshes_topology() {
    let mut control = TmuxControl {
        active: true,
        control_client_admitted: true,
        ..Default::default()
    };
    control
        .feed(b"%subscription-changed satin-pane-title $0 @2 0 %7 : \\342\\240\\271 satin\n")
        .unwrap();

    let command = control.take_outgoing().unwrap();
    assert!(
        String::from_utf8(command)
            .unwrap()
            .starts_with("list-panes -s")
    );
}

#[test]
fn initial_handshake_subscribes_to_pane_titles() {
    let mut control = TmuxControl::default();
    control
        .feed(b"\x1bP1000p%begin 1 1 0\n%end 1 1 0\n")
        .unwrap();

    assert_eq!(
        control.take_outgoing().unwrap(),
        format!("{}\n", admission::CONTROL_CLIENT_CHECK_COMMAND).as_bytes()
    );
    control
        .feed(b"%begin 1 2 0\n1\n%end 1 2 0\n")
        .unwrap();
    assert_eq!(
        control.take_outgoing().unwrap(),
        b"refresh-client -f pause-after=5 -B 'satin-pane-title:%*:#{q:pane_title}' \
          -B 'satin-session-clients::#{session_attached_list}'\n"
    );
    assert!(
        String::from_utf8(control.take_outgoing().unwrap())
            .unwrap()
            .starts_with("list-panes -s")
    );
}

#[test]
fn duplicate_control_client_is_rejected_without_waiting() {
    let mut control = TmuxControl::default();
    control
        .feed(b"\x1bP1000p%begin 1 1 0\n%end 1 1 0\n")
        .unwrap();
    assert!(control.take_outgoing().is_some());
    control
        .feed(b"%begin 1 2 0\n1\n1\n%end 1 2 0\n")
        .unwrap();
    assert!(matches!(
        control.take_event(),
        Some(TmuxControlEvent::Entered)
    ));
    assert!(matches!(
        control.take_event(),
        Some(TmuxControlEvent::ProtocolError { .. })
    ));
    assert_eq!(control.take_outgoing().unwrap(), b"detach-client\n");
}

#[test]
fn later_control_client_attachment_revokes_projection() {
    let mut control = TmuxControl {
        active: true,
        control_client_admitted: true,
        ..Default::default()
    };
    control
        .feed(b"%subscription-changed satin-session-clients $0 : /dev/ttys001\n")
        .unwrap();
    assert_eq!(
        control.take_outgoing().unwrap(),
        format!("{}\n", admission::CONTROL_CLIENT_CHECK_COMMAND).as_bytes()
    );
    control
        .feed(b"%begin 1 2 0\n1\n1\n%end 1 2 0\n")
        .unwrap();
    assert!(matches!(
        control.take_event(),
        Some(TmuxControlEvent::ProtocolError { .. })
    ));
    assert_eq!(control.take_outgoing().unwrap(), b"detach-client\n");
}

#[test]
fn topology_change_while_snapshot_pending_queues_trailing_sync() {
    let mut control = TmuxControl {
        active: true,
        control_client_admitted: true,
        hydrated_panes: [7].into(),
        ..Default::default()
    };
    control.request_sync();
    assert!(
        String::from_utf8(control.take_outgoing().unwrap())
            .unwrap()
            .starts_with("list-panes -s")
    );

    control.feed(b"%layout-change @1 changed\n").unwrap();
    assert!(control.outgoing.is_empty());

    let row = snapshot_row("/tmp", 0, false, false);
    control
        .feed(format!("%begin 1 2 0\n{row}\n%end 1 2 0\n").as_bytes())
        .unwrap();
    assert!(
        String::from_utf8(control.take_outgoing().unwrap())
            .unwrap()
            .starts_with("list-panes -s")
    );
    assert!(control.sync_pending);
    assert!(!control.sync_requested_while_pending);
}

#[test]
fn rehydration_forwards_live_scroll_metadata_without_replaying_cells() {
    let mut control = TmuxControl {
        rehydrating_panes: [7].into(),
        ..Default::default()
    };
    control.push_output(7, b"updated cells\x1b[1;22r\x1b[H\x1b[".to_vec());
    assert!(control.take_event().is_none());
    control.push_output(7, b"11M\x1b[1;24r".to_vec());

    assert_eq!(
        control.take_event(),
        Some(TmuxControlEvent::PaneScrollMetadata {
            pane_id: 7,
            rows: 11,
            region_top: Some(1),
            region_bottom: Some(22),
            region_left: None,
            region_right: None,
        })
    );
    assert!(control.take_event().is_none());
}
