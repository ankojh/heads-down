"""Compare question phrasings on the labeled screen regions.

Usage: python bench/phrasing.py [--device mps|cpu]
"""
import argparse

import laya
from cases import CASES, QUESTIONS, state_for

VARIANTS = {
    "distracting_noul": QUESTIONS["distracting"],
    "relevant_noul": {
        "type": "noul",
        "instructions": "Does this screen region help the user complete their current task?",
        "criteria": {"false": "Not useful for the current task", "true": "Useful for the current task"},
    },
    "keep_or_blur_choice": {
        "type": "choice",
        "instructions": "Given the user's current task, what should a focus app do with this screen region?",
        "criteria": {
            "keep": "It is about the same topic as the task or is a tool for doing it, even on a site like YouTube or Reddit",
            "blur": "It is entertainment, social chatter or news unrelated to the task's topic",
        },
    },
    "topic_noul": {
        "type": "noul",
        "instructions": "Is the content of this screen region on the same subject as the user's current task? "
        "Judge the content itself, not the website or app it appears in.",
        "criteria": {"false": "Different subject", "true": "Same subject or a tool used for the task"},
    },
}

# For each variant, how to turn its answer into P(distracting).
TO_P_DISTRACTING = {
    "distracting_noul": lambda a: a["noul"],
    "relevant_noul": lambda a: 1 - a["noul"],
    "keep_or_blur_choice": lambda a: a["probabilities"]["blur"],
    "topic_noul": lambda a: 1 - a["noul"],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="mps")
    args = ap.parse_args()

    agent = laya.load("convaiinnovations/laya", device=args.device)
    states = [state_for(task, region) for task, region, _, _ in CASES]
    n_tricky = sum(tricky for *_, tricky in CASES)
    for name, question in VARIANTS.items():
        results = agent.predict_batch(states, {"q": question}, batch_size=16)
        correct = tricky_correct = 0
        for (_, _, label, tricky), out in zip(CASES, results, strict=True):
            ok = (TO_P_DISTRACTING[name](out["answers"]["q"]) >= 0.5) == label
            correct += ok
            tricky_correct += ok and tricky
        print(f"{name:20s} accuracy {correct}/{len(CASES)} = {correct / len(CASES):.0%}   tricky {tricky_correct}/{n_tricky}")


if __name__ == "__main__":
    main()
