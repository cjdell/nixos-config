# Circadian Lighting breaks on Home Assistant 2026.10.0 (`_is_sleep`/`_is_disabled` unguarded `states.get`)

Report-ready write-up for an upstream issue against
[`claytonjn/hass-circadian_lighting`](https://github.com/claytonjn/hass-circadian_lighting).
Everything below was observed on a live install; the local workaround is a small
patch to `custom_components/circadian_lighting/switch.py`.

## Summary

On HA 2026.10.0, every `switch` entity created by the `circadian_lighting`
platform fails to register if its configured `sleep_entity` (or `disable_entity`)
is not yet present in the state machine at entity-add time. `_is_sleep()` and
`_is_disabled()` call `self.hass.states.get(entity_id).state` without checking
that `states.get()` actually returned a state, so an unavailable/not-yet-loaded
helper raises `AttributeError` during `extra_state_attributes`, which aborts
entity registration. Because the platform's state-change listeners are not
released on that abort, the dead listener then keeps raising a second
`AttributeError` on every tracked light change.

Affected version: **2.1.6** (upstream `master` is byte-identical, so there is no
fixed release to upgrade to).

## Environment

- Home Assistant **2026.10.0** (container image `linuxserver/homeassistant:latest`,
  Python 3.14)
- Integration: `circadian_lighting` 2.1.6 (HACS), domain
  `custom_components/circadian_lighting`
- Configuration uses UI helpers (`input_boolean.sleep`, `input_boolean.octopus_go`)
  as `sleep_entity` / `disable_entity`

## Symptoms

- The three configured switches are reported unavailable/missing and do nothing:
  - `switch.circadian_lighting_sun_emulator`
  - `switch.circadian_lighting_sun_emulator_kitchen_spots`
  - `switch.circadian_lighting_sun_emulator_brighter_at_sleep`
- Log warnings when automations or services reference them:

  ```
  WARNING (MainThread) [homeassistant.helpers.service]
  Referenced entities switch.circadian_lighting_sun_emulator,
  switch.circadian_lighting_sun_emulator_brighter_at_sleep,
  switch.circadian_lighting_sun_emulator_kitchen_spots are missing or not currently available
  ```

- Two repeated errors in `home-assistant.log`.

### Error 1 — at startup, entity cannot be added

```
2026-10-08 02:01:59.674 ERROR (MainThread) [homeassistant.components.switch]
Error adding entity switch.circadian_lighting_sun_emulator for domain switch with platform circadian_lighting
Traceback (most recent call last):
  File ".../homeassistant/helpers/entity_platform.py", line 725, in _async_add_entities
    await self._async_add_entity(entity, False, entity_registry, config_subentry_id)
  File ".../homeassistant/helpers/entity_platform.py", line 907, in _async_add_entity
    await entity.add_to_platform_finish()
  File ".../homeassistant/helpers/entity.py", line 1452, in add_to_platform_finish
    self.async_write_ha_state()
  File ".../homeassistant/helpers/entity.py", line 1067, in async_write_ha_state
    self._async_write_ha_state()
  File ".../homeassistant/helpers/entity.py", line 1219, in _async_write_ha_state
    ) = self.__async_calculate_state()
  File ".../homeassistant/helpers/entity.py", line 1129, in __async_calculate_state
    if extra_state_attributes := self.extra_state_attributes:
  File "/config/custom_components/circadian_lighting/switch.py", line 265, in extra_state_attributes
    return {"hs_color": self._hs_color, "brightness": self._brightness, "colortemp": self._color_temperature()}
  File "/config/custom_components/circadian_lighting/switch.py", line 287, in _color_temperature
    if not self._is_sleep()
  File "/config/custom_components/circadian_lighting/switch.py", line 281, in _is_sleep
    and self.hass.states.get(self._sleep_entity).state in self._sleep_state
AttributeError: 'NoneType' object has no attribute 'state'
```

(`states.get(...)` returned `None` because `input_boolean.sleep` had not been
loaded/restored yet — the `self._sleep_entity is not None` check is about the
*configured* entity id, not the *current state*.)

### Error 2 — afterwards, on every tracked light change

```
2026-10-08 02:14:07.878 ERROR (MainThread) [homeassistant] Error doing job: Task exception was never retrieved (task: None)
Traceback (most recent call last):
  File "/config/custom_components/circadian_lighting/switch.py", line 386, in _light_state_changed
    await self._force_update_switch(lights=[entity_id])
  File "/config/custom_components/circadian_lighting/switch.py", line 319, in _force_update_switch
    return await self._update_switch(lights, transition=self._initial_transition, force=True)
  File "/config/custom_components/circadian_lighting/switch.py", line 314, in _update_switch
    self._hs_color = self._calc_hs()
  ...
  File "/config/custom_components/circadian_lighting/switch.py", line 281, in _is_sleep
    and self.hass.states.get(self._sleep_entity).state in self._sleep_state
AttributeError: 'NoneType' object has no attribute 'states'
```

Here the `NoneType` is `self.hass` (see next section) — the entity was aborted
but its listeners were never removed.

## Root cause

Two independent defects in `switch.py` combine:

1. **No guard for a missing state (or a missing `hass`).** `_is_sleep()` and
   `_is_disabled()` only check the entity id is configured, then dereference
   `self.hass.states.get(...).state`. A configured-but-not-yet-loaded helper
   (common for UI helpers, whose integration can load after the `switch`
   platform) yields `None`.

2. **Listeners registered in `async_added_to_hass` are not tied to the entity
   lifecycle.** The three `async_track_state_change_event(...)` calls are not
   wrapped in `async_on_remove(...)`. When `add_to_platform_finish()` raises,
   HA calls `Entity.add_to_platform_abort()`, which sets `self.hass = None`
   (see HA `homeassistant/helpers/entity.py`). The un-released listeners keep
   firing with `self.hass is None`, hence the second traceback on every light
   change and log spam.

## Reproduction

1. Define a UI helper `input_boolean.sleep`.
2. Configure a `circadian_lighting` switch with `sleep_entity: input_boolean.sleep`.
3. Restart HA. The switch fails to be added with Error 1; turning any tracked
   light on then produces Error 2.

## Local fix (workaround)

Applied to
`/srv/homeassistant/config/custom_components/circadian_lighting/switch.py`
(source matches upstream 2.1.6 / current `master`; the diff is against
upstream).

### 1. Guard the sleep/disable checks

```diff
     def _is_sleep(self):
-        return (
-            self._sleep_entity is not None
-            and self.hass.states.get(self._sleep_entity).state in self._sleep_state
-        )
+        if self._sleep_entity is None:
+            return False
+        state = self.hass.states.get(self._sleep_entity)
+        return state is not None and state.state in self._sleep_state
```

```diff
     def _is_disabled(self):
-        return (
-            self._disable_entity is not None
-            and self.hass.states.get(self._disable_entity).state in self._disable_state
-        )
+        if self._disable_entity is None:
+            return False
+        state = self.hass.states.get(self._disable_entity)
+        return state is not None and state.state in self._disable_state
```

### 2. Release the state-change listeners on remove

```diff
         # Add listeners
-        async_track_state_change_event(
-            self.hass, self._lights, self._light_state_changed
-        )
-        track_kwargs = dict(hass=self.hass, action=self._state_changed)
-        if self._sleep_entity is not None:
-            sleep_kwargs = dict(track_kwargs, entity_ids=self._sleep_entity)
-            async_track_state_change_event(**sleep_kwargs)
-
-        if self._disable_entity is not None:
-            async_track_state_change_event(
-                self.hass, self._disable_entity, self._state_changed
-            )
+        self.async_on_remove(
+            async_track_state_change_event(
+                self.hass, self._lights, self._light_state_changed
+            )
+        )
+        if self._sleep_entity is not None:
+            self.async_on_remove(
+                async_track_state_change_event(
+                    self.hass, self._sleep_entity, self._state_changed
+                )
+            )
+
+        if self._disable_entity is not None:
+            self.async_on_remove(
+                async_track_state_change_event(
+                    self.hass, self._disable_entity, self._state_changed
+                )
+            )
```

Both changes together are the minimal robust fix; part 1 alone makes the
entities register, part 2 stops the listener leak.

## Notes for the maintainer

- The guard should arguably also handle `self.hass is None` defensively, but
  with part 2 applied the abort path no longer leaves live listeners.
- `extra_state_attributes` calling `_color_temperature()` means a missing sleep
  state is fatal at add time; making the attribute calculation tolerant of an
  unloaded helper is the key invariant.
- Upstream `master` == tag 2.1.6, so this affects the latest code.

## Follow-up on the local host

- This file lives outside the Nix config (`/srv/homeassistant/config`), so a
  HACS update of the component will overwrite the patch.
- The patch only takes effect on the next HA start (or a YAML reload of the
  switch platform); the already-aborted entities are not re-added by the running
  process.
