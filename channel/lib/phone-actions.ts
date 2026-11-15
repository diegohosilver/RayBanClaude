/**
 * Actions Claude can trigger on the iPhone (`phone_action` tool):
 * timer, alarm, cancel timer, call, message, navigation, reminder,
 * save photo to the library, location (also "remember where I parked").
 *
 * Every action is validated here via an allowlist. Calls, messages and navigation
 * are always confirmed by the user on the iPhone – Claude cannot trigger anything secretly.
 */

import { CLOCK_TIME, ISO_DATE, PHONE } from './patterns.ts'
import { cleanText } from './validate.ts'

export const PHONE_ACTIONS = [
  'timer', 'alarm', 'cancel_timer', 'call', 'message', 'navigate', 'reminder', 'save_photo', 'location',
] as const
export type PhoneActionName = (typeof PHONE_ACTIONS)[number]

const MAX_TIMER_SECONDS = 86_400 // 24 hours
const MAX_LABEL_CHARS = 60
const MAX_CONTACT_CHARS = 80
const MAX_MESSAGE_CHARS = 1000
const MAX_DESTINATION_CHARS = 200
const MAX_REMINDER_CHARS = 200

/** Sanitised payload sent to the app (known fields only). */
export interface PhoneActionPayload {
  readonly action: PhoneActionName
  readonly duration_seconds?: number
  readonly time?: string
  readonly date?: string
  readonly label?: string
  readonly contact?: string
  readonly number?: string
  readonly text?: string
  readonly destination?: string
}

/** Error with a message Claude can understand directly and relay to the user. */
export class PhoneActionError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'PhoneActionError'
  }
}

type Args = Readonly<Record<string, unknown>>

function optionalText(raw: unknown, max: number): string | undefined {
  return cleanText(raw, max) || undefined
}

function requireContactOrNumber(args: Args): Pick<PhoneActionPayload, 'contact' | 'number'> {
  const contact = optionalText(args.contact, MAX_CONTACT_CHARS)
  const rawNumber = typeof args.number === 'string' ? args.number.trim() : ''
  if (rawNumber && !PHONE.test(rawNumber)) throw new PhoneActionError('number is not a valid phone number')
  const number = rawNumber || undefined
  if (!contact && !number) throw new PhoneActionError('contact (name as spoken by the user) or number is required')
  return { contact, number }
}

const BUILDERS: Readonly<Record<PhoneActionName, (args: Args) => PhoneActionPayload>> = {
  timer: args => {
    const seconds = Number(args.duration_seconds)
    if (!Number.isInteger(seconds) || seconds < 1 || seconds > MAX_TIMER_SECONDS) {
      throw new PhoneActionError(`duration_seconds must be an integer between 1 and ${MAX_TIMER_SECONDS}`)
    }
    return { action: 'timer', duration_seconds: seconds, label: optionalText(args.label, MAX_LABEL_CHARS) }
  },
  alarm: args => {
    const time = typeof args.time === 'string' ? args.time.trim() : ''
    if (!CLOCK_TIME.test(time)) throw new PhoneActionError('time must be given in the format HH:MM (24 h)')
    return { action: 'alarm', time, label: optionalText(args.label, MAX_LABEL_CHARS) }
  },
  cancel_timer: args => ({ action: 'cancel_timer', label: optionalText(args.label, MAX_LABEL_CHARS) }),
  call: args => ({ action: 'call', ...requireContactOrNumber(args) }),
  message: args => {
    const text = optionalText(args.text, MAX_MESSAGE_CHARS)
    if (!text) throw new PhoneActionError('text is required')
    return { action: 'message', ...requireContactOrNumber(args), text }
  },
  navigate: args => {
    const destination = optionalText(args.destination, MAX_DESTINATION_CHARS)
    if (!destination) throw new PhoneActionError('destination is required')
    return { action: 'navigate', destination }
  },
  reminder: args => {
    const text = optionalText(args.text, MAX_REMINDER_CHARS)
    if (!text) throw new PhoneActionError('text (what to be reminded of) is required')
    const time = typeof args.time === 'string' ? args.time.trim() : ''
    const date = typeof args.date === 'string' ? args.date.trim() : ''
    if (time && !CLOCK_TIME.test(time)) throw new PhoneActionError('time must be given in the format HH:MM (24 h)')
    if (date && !ISO_DATE.test(date)) throw new PhoneActionError('date must be given in the format YYYY-MM-DD')
    return { action: 'reminder', text, time: time || undefined, date: date || undefined }
  },
  save_photo: () => ({ action: 'save_photo' }),
  location: args => ({ action: 'location', label: optionalText(args.label, MAX_LABEL_CHARS) }),
}

function isPhoneAction(raw: unknown): raw is PhoneActionName {
  return PHONE_ACTIONS.some(a => a === raw)
}

/** Validates the tool arguments and returns the sanitised payload for the app. */
export function buildPhoneAction(args: Args): PhoneActionPayload {
  if (!isPhoneAction(args.action)) throw new PhoneActionError(`action must be one of ${PHONE_ACTIONS.join(', ')}`)
  return BUILDERS[args.action](args)
}

export const PHONE_ACTION_TOOL = {
  name: 'phone_action',
  description: [
    "Do something on the user's iPhone: set a timer or alarm, cancel timers, start a phone call,",
    'prepare a text message, start navigation, add a reminder (iOS Reminders app), save the last photo',
    'to the photo library (save_photo – when the user says "mach ein Foto" / "speicher das Foto"),',
    'or get the current location (location – "wo bin ich?"; with label it is also remembered, e.g.',
    'label "Auto geparkt" for "merk dir, wo ich geparkt habe"; navigate back later with the stored address).',
    'For call/message pass the contact name exactly as the user said it (e.g. "Mama") – the phone looks',
    'it up locally, contacts never leave the phone. Calls, messages and navigation are always confirmed',
    'by the user on the phone. The result tells you whether it worked.',
  ].join(' '),
  inputSchema: {
    type: 'object',
    properties: {
      action: { type: 'string', enum: [...PHONE_ACTIONS] },
      duration_seconds: { type: 'integer', description: 'timer: duration in seconds (1–86400)' },
      time: { type: 'string', description: 'alarm/reminder: local time HH:MM (24 h); alarm = next occurrence' },
      date: { type: 'string', description: 'reminder: day as YYYY-MM-DD (omit for today/next occurrence of time)' },
      label: { type: 'string', description: 'timer/alarm: short name, e.g. "Nudeln"; cancel_timer: which one (empty = all); location: name to remember the place by' },
      contact: { type: 'string', description: 'call/message: contact name as spoken by the user' },
      number: { type: 'string', description: 'call/message: phone number, only if the user said one' },
      text: { type: 'string', description: 'message: the message text; reminder: what to remind of' },
      destination: { type: 'string', description: 'navigate: address or place' },
    },
    required: ['action'],
  },
} as const
