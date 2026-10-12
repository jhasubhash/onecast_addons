import { makeExpiringStatusCommand } from "./status-command";
import { expirationAtIst } from "./slack";

// On Call auto-clears at 8:30 PM IST (20:30 UTC+5:30).
export default makeExpiringStatusCommand(
  ":telephone_receiver:",
  "On Call",
  () => expirationAtIst(20, 30),
  "until 8:30 PM IST",
);
