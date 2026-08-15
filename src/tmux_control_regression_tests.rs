#[test]
fn session_notification_requests_and_parses_topology() {
    let mut control = TmuxControl::default();
    control
        .feed(b"\x1bP1000p%session-changed $0 satin\n")
        .unwrap();
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
        b"refresh-client -f pause-after=5 -B 'satin-pane-title:%*:#{q:pane_title}'\n"
    );
    assert!(
        String::from_utf8(control.take_outgoing().unwrap())
            .unwrap()
            .starts_with("list-panes -s")
    );
}
