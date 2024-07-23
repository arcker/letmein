// -*- coding: utf-8 -*-
//
// Copyright (C) 2024 Michael Büsch <m@bues.ch>
//
// Licensed under the Apache License version 2.0
// or the MIT license, at your option.
// SPDX-License-Identifier: Apache-2.0 OR MIT

#![forbid(unsafe_code)]

#[cfg(not(any(target_os = "linux", target_os = "android")))]
std::compile_error!("letmeind server and letmein-systemd do not support non-Linux platforms.");

mod firewall;
mod processor;
mod server;

use crate::{
    firewall::{nftables::NftFirewall, FirewallMaintain},
    processor::Processor,
    server::Server,
};
use anyhow::{self as ah, format_err as err, Context as _};
use clap::Parser;
use letmein_conf::{Config, ConfigVariant, INSTALL_PREFIX, SERVER_CONF_PATH};
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::{
    signal::unix::{signal, SignalKind},
    sync::{self, Mutex, RwLock, RwLockReadGuard, Semaphore},
    task, time,
};

const FW_MAINTAIN_PERIOD: Duration = Duration::from_millis(5000);

pub type ConfigRef<'a> = RwLockReadGuard<'a, Config>;

#[derive(Parser, Debug, Clone)]
struct Opts {
    /// Override the default path to the configuration file.
    #[arg(short, long)]
    config: Option<PathBuf>,

    /// Maximum number of simultaneous connections.
    #[arg(short, long, default_value = "8")]
    num_connections: usize,

    /// Force-disable use of systemd socket.
    ///
    /// Do not use systemd socket,
    /// even if a systemd socket has been passed to the application.
    #[arg(long, default_value = "false")]
    no_systemd: bool,
}

impl Opts {
    pub fn get_config(&self) -> PathBuf {
        if let Some(config) = &self.config {
            config.clone()
        } else {
            format!("{INSTALL_PREFIX}{SERVER_CONF_PATH}").into()
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ah::Result<()> {
    let opts = Opts::parse();

    let mut conf = Config::new(ConfigVariant::Server);
    conf.load(&opts.get_config())
        .context("Configuration file")?;
    let conf = Arc::new(RwLock::new(conf));

    let fw = Arc::new(Mutex::new(NftFirewall::new(&conf.read().await).await?));

    let mut sigterm = signal(SignalKind::terminate()).unwrap();
    let mut sigint = signal(SignalKind::interrupt()).unwrap();
    let mut sighup = signal(SignalKind::hangup()).unwrap();

    let (exit_sock_tx, mut exit_sock_rx) = sync::mpsc::channel(1);
    let (exit_fw_tx, mut exit_fw_rx) = sync::mpsc::channel(1);

    let srv = Server::new(&conf.read().await, opts.no_systemd)
        .await
        .context("Server init")?;

    // Task: Socket handler.
    let conf_clone = Arc::clone(&conf);
    let fw_clone = Arc::clone(&fw);
    task::spawn(async move {
        let conn_semaphore = Semaphore::new(opts.num_connections);
        loop {
            let conf = Arc::clone(&conf_clone);
            let fw = Arc::clone(&fw_clone);
            match srv.accept().await {
                Ok(conn) => {
                    // Socket connection handler.
                    if let Ok(_permit) = conn_semaphore.acquire().await {
                        task::spawn(async move {
                            let conf = conf.read().await;
                            let mut proc = Processor::new(conn, &conf, fw);
                            if let Err(e) = proc.run().await {
                                eprintln!("Client error: {e}");
                            }
                        });
                    }
                }
                Err(e) => {
                    let _ = exit_sock_tx.send(Err(e)).await;
                    break;
                }
            }
        }
    });

    // Task: Firewall.
    let conf_clone = Arc::clone(&conf);
    let fw_clone = Arc::clone(&fw);
    task::spawn(async move {
        let mut interval = time::interval(FW_MAINTAIN_PERIOD);
        loop {
            interval.tick().await;
            let conf = conf_clone.read().await;
            let mut fw = fw_clone.lock().await;
            if let Err(e) = fw.maintain(&conf).await {
                let _ = exit_fw_tx.send(Err(e)).await;
                break;
            }
        }
    });

    // Task: Main loop.
    let mut exitcode;
    loop {
        tokio::select! {
            _ = sigterm.recv() => {
                eprintln!("SIGTERM: Terminating.");
                exitcode = Ok(());
                break;
            }
            _ = sigint.recv() => {
                exitcode = Err(err!("Interrupted by SIGINT."));
                break;
            }
            _ = sighup.recv() => {
                println!("SIGHUP: Reloading.");
                {
                    let mut conf = conf.write().await;
                    if let Err(e) = conf.load(&opts.get_config()) {
                        eprintln!("Failed to load configuration file: {e}");
                    }
                }
                {
                    let conf = conf.read().await;
                    let mut fw = fw.lock().await;
                    if let Err(e) = fw.reload(&conf).await {
                        eprintln!("Failed to reload filewall rules: {e}");
                    }
                }
            }
            code = exit_sock_rx.recv() => {
                exitcode = code.unwrap_or_else(|| Err(err!("Unknown error code.")));
                break;
            }
            code = exit_fw_rx.recv() => {
                exitcode = code.unwrap_or_else(|| Err(err!("Unknown error code.")));
                break;
            }
        }
    }

    // Exiting...
    // Try to remove all firewall rules.
    {
        let conf = conf.read().await;
        let mut fw = fw.lock().await;
        if let Err(e) = fw.clear(&conf).await {
            eprintln!("WARNING: Failed to remove firewall rules: {e}");
            if exitcode.is_ok() {
                exitcode = Err(err!("Failed to remove firewall rules"));
            }
        }
    }

    exitcode
}

// vim: ts=4 sw=4 expandtab
