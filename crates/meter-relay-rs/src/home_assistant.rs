use serde_json::json;

#[derive(Clone)]
pub struct HomeAssistant {
    client: reqwest::Client,
    api: String,
    token: String,
}

impl HomeAssistant {
    pub fn new(api: String, token: String) -> Self {
        Self {
            client: reqwest::Client::new(),
            api: api.trim_end_matches('/').to_string(),
            token,
        }
    }

    pub async fn send(&self, id: &str, name: &str, value: f64, unit: &str) {
        self.send_state(id, name, json!(value), unit).await;
    }

    pub async fn send_str(&self, id: &str, name: &str, value: &str, unit: &str) {
        self.send_state(id, name, json!(value), unit).await;
    }

    async fn send_state(&self, id: &str, name: &str, value: serde_json::Value, unit: &str) {
        let url = format!("{}/api/states/sensor.{}", self.api, id);

        let body = json!({
            "state": value,
            "attributes": {
                "unit_of_measurement": if unit.is_empty() { serde_json::Value::Null } else { json!(unit) },
                "device_class": if unit == "W" { json!("power") } else { serde_json::Value::Null },
                "state_class": if unit == "W" { json!("measurement") } else { serde_json::Value::Null },
                "friendly_name": name,
            }
        });

        match self
            .client
            .post(&url)
            .bearer_auth(&self.token)
            .json(&body)
            .send()
            .await
        {
            Ok(res) if res.status().is_success() => {}
            Ok(res) => tracing::warn!(id, status = %res.status(), "Home Assistant rejected state"),
            Err(err) => tracing::warn!(id, "Home Assistant request failed: {err}"),
        }
    }

    pub async fn read_float(&self, id: &str) -> f64 {
        match self.read_state("sensor", id).await {
            Some(state) => state.parse().unwrap_or(0.0),
            None => 0.0,
        }
    }

    pub async fn read_boolean(&self, id: &str) -> bool {
        self.read_state("input_boolean", id).await.as_deref() == Some("on")
    }

    async fn read_state(&self, domain: &str, id: &str) -> Option<String> {
        let url = format!("{}/api/states/{}.{}", self.api, domain, id);

        let response = match self
            .client
            .get(&url)
            .bearer_auth(&self.token)
            .send()
            .await
        {
            Ok(response) => response,
            Err(err) => {
                tracing::warn!(id, "Home Assistant read failed: {err}");
                return None;
            }
        };

        if !response.status().is_success() {
            tracing::warn!(id, status = %response.status(), "Home Assistant read returned an error");
            return None;
        }

        match response.json::<serde_json::Value>().await {
            Ok(json) => json.get("state").and_then(|s| s.as_str()).map(str::to_string),
            Err(err) => {
                tracing::warn!(id, "Home Assistant returned invalid JSON: {err}");
                None
            }
        }
    }
}
