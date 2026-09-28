use std::time::Duration;

use tokio::sync::mpsc;

/// Batched, non-blocking InfluxDB line-protocol writer.
///
/// Points are queued on an unbounded channel and flushed either when the batch
/// reaches `MAX_BATCH` or every `FLUSH_INTERVAL`, so the control loop never
/// blocks on network I/O.
const MAX_BATCH: usize = 500;
const FLUSH_INTERVAL: Duration = Duration::from_millis(1_000);

#[derive(Clone)]
pub struct InfluxWriter {
    tx: mpsc::UnboundedSender<String>,
}

impl InfluxWriter {
    pub fn new(url: String, token: String) -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();

        let endpoint = format!(
            "{}/api/v2/write?org=Home&bucket=Meter&precision=ms",
            url.trim_end_matches('/')
        );

        let client = reqwest::Client::new();

        tokio::spawn(async move {
            let mut batch: Vec<String> = Vec::new();
            let mut interval = tokio::time::interval(FLUSH_INTERVAL);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

            loop {
                tokio::select! {
                    maybe = rx.recv() => {
                        match maybe {
                            Some(line) => {
                                batch.push(line);
                                if batch.len() >= MAX_BATCH {
                                    flush(&client, &endpoint, &token, &mut batch).await;
                                }
                            }
                            None => {
                                if !batch.is_empty() {
                                    flush(&client, &endpoint, &token, &mut batch).await;
                                }
                                break;
                            }
                        }
                    }
                    _ = interval.tick() => {
                        if !batch.is_empty() {
                            flush(&client, &endpoint, &token, &mut batch).await;
                        }
                    }
                }
            }
        });

        Self { tx }
    }

    pub fn write(&self, line: String) {
        let _ = self.tx.send(line);
    }
}

async fn flush(
    client: &reqwest::Client,
    endpoint: &str,
    token: &str,
    batch: &mut Vec<String>,
) {
    let body = batch.join("\n");
    batch.clear();

    match client
        .post(endpoint)
        .bearer_auth(token)
        .header("Content-Type", "text/plain; charset=utf-8")
        .body(body)
        .send()
        .await
    {
        Ok(res) if res.status().is_success() => {}
        Ok(res) => tracing::warn!(status = %res.status(), "InfluxDB write rejected"),
        Err(err) => tracing::warn!("InfluxDB write failed: {err}"),
    }
}
