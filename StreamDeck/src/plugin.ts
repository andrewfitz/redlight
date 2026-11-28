import streamDeck from "@elgato/streamdeck";
import { registerActions } from "./actions/index.js";
import { createRuntime } from "./redlight/runtime.js";

const runtime = createRuntime();
registerActions(runtime);
streamDeck.connect();
