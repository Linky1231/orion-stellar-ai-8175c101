// Complete instruction-tuned model; low-bit quantization retains all model layers.
export const LOCAL_MODEL = {
  name: "Gemma 3 270M Instruct",
  quantization: "UD-IQ3_XXS",
  source: "https://huggingface.co/unsloth/gemma-3-270m-it-GGUF",
  maxTokens: 768,
  temperature: 1.0,
  topK: 64,
  topP: 0.95,
  minP: 0.0,
  system: "Eres Orión Estellar. Responde en español con oraciones completas y naturales. Responde directamente a la pregunta. No inventes información si no la sabes. Cuando te pidan una explicación, incluye los pasos necesarios, sin limitarte a palabras sueltas.",
} as const;