"""Labeled screen regions for evaluating distraction decisions.

Each case is (task, region, is_distraction). Labels are hand-written judgments of
whether a region pulls the user away from the stated task. The `tricky` flag marks
cases where a fixed blocklist would get the answer wrong.
"""

STUDY = "Studying for my Product Management class: reading about prioritization frameworks (RICE, Kano) for Thursday's quiz"
CODE = "Writing the Python backend for my group project's REST API, due tonight"
SYNC = "Group project sync call with my teammates to divide up the remaining work"
ESSAY = "Writing my history essay on the causes of World War I"

CASES = [
    # --- Studying for PM class ---
    (STUDY, {"app": "Safari", "title": "RICE Scoring Model - ProductPlan", "url": "productplan.com/glossary/rice-scoring-model", "text": "RICE is a prioritization framework: Reach, Impact, Confidence, Effort"}, False, False),
    (STUDY, {"app": "Preview", "title": "PM_Week6_Prioritization.pdf", "text": "The Kano model classifies features as basic, performance, or delighters"}, False, False),
    (STUDY, {"app": "Notion", "title": "PM Class Notes", "text": "Quiz Thursday. Know RICE formula = (Reach x Impact x Confidence) / Effort"}, False, False),
    (STUDY, {"app": "Chrome", "title": "YouTube", "url": "youtube.com/watch", "text": "Kano Model Explained in 8 Minutes | Product School"}, False, True),
    (STUDY, {"app": "Chrome", "title": "YouTube", "url": "youtube.com", "text": "Recommended: MrBeast - I Survived 50 Hours In Antarctica. 12M views"}, True, False),
    (STUDY, {"app": "Chrome", "title": "YouTube", "url": "youtube.com/shorts", "text": "Shorts: funniest cat fails compilation"}, True, False),
    (STUDY, {"app": "Chrome", "title": "Reddit - r/nba", "url": "reddit.com/r/nba", "text": "[Highlight] LeBron with the poster dunk in OT"}, True, False),
    (STUDY, {"app": "Chrome", "title": "Reddit - r/ProductManagement", "url": "reddit.com/r/ProductManagement", "text": "How do you actually use RICE in practice? Our team found Confidence is always gamed"}, False, True),
    (STUDY, {"app": "Discord", "title": "#memes - Gaming Squad", "text": "jake: lmaooo look at this clip. anyone on for valorant tonight?"}, True, False),
    (STUDY, {"app": "Instagram", "title": "Instagram", "url": "instagram.com", "text": "Reels: Day in my life as a college student in NYC"}, True, False),
    (STUDY, {"app": "Messages", "title": "Mom", "text": "Did you eat dinner? Call me when you're free"}, True, False),
    (STUDY, {"app": "Slack", "title": "#pm-class-401", "text": "Prof. Lee: Reminder, Thursday's quiz covers chapters 5-6, prioritization frameworks only"}, False, True),
    (STUDY, {"app": "Amazon", "title": "Amazon.com: Sony WH-1000XM5", "url": "amazon.com", "text": "Deal of the day: Sony noise cancelling headphones 30% off"}, True, False),
    (STUDY, {"app": "Chrome", "title": "Twitter / X", "url": "x.com/home", "text": "For you: trending - #Eurovision, celebrity breakup drama"}, True, False),
    (STUDY, {"app": "Chrome", "title": "Quizlet", "url": "quizlet.com", "text": "PM Prioritization flashcards: What does the E in RICE stand for?"}, False, False),
    (STUDY, {"app": "Gmail", "title": "Inbox", "text": "Spotify: Your Wrapped is here! See your top songs of the year"}, True, False),

    # --- Coding the backend ---
    (CODE, {"app": "VS Code", "title": "api/routes.py", "text": "@app.post('/tasks') def create_task(payload: TaskIn): ..."}, False, False),
    (CODE, {"app": "Terminal", "title": "zsh", "text": "pytest tests/test_routes.py FAILED test_create_task - AssertionError 422"}, False, False),
    (CODE, {"app": "Chrome", "title": "Stack Overflow", "url": "stackoverflow.com", "text": "FastAPI returns 422 Unprocessable Entity on POST with pydantic model"}, False, False),
    (CODE, {"app": "Chrome", "title": "FastAPI docs", "url": "fastapi.tiangolo.com/tutorial/body", "text": "Request Body - declare a request body using Pydantic models"}, False, False),
    (CODE, {"app": "Chrome", "title": "YouTube", "url": "youtube.com/watch", "text": "FastAPI Full Course for Beginners - build a REST API in Python"}, False, True),
    (CODE, {"app": "Chrome", "title": "YouTube", "url": "youtube.com/watch", "text": "Top 10 Anime Fights of All Time"}, True, False),
    (CODE, {"app": "Chrome", "title": "Hacker News", "url": "news.ycombinator.com", "text": "Show HN: I built a Rust game engine in 30 days; Ask HN: what are you reading"}, True, True),
    (CODE, {"app": "Slack", "title": "#group-project", "text": "Priya: I pushed the frontend form, can you make POST /tasks accept due_date?"}, False, True),
    (CODE, {"app": "Discord", "title": "#general - Gaming Squad", "text": "anyone want to queue ranked? need a 5th"}, True, False),
    (CODE, {"app": "Chrome", "title": "GitHub - group-project/backend PR #12", "url": "github.com", "text": "Review requested: add due_date field to Task model"}, False, False),
    (CODE, {"app": "Netflix", "title": "Netflix", "url": "netflix.com", "text": "Continue watching: Stranger Things S4 E7"}, True, False),
    (CODE, {"app": "ChatGPT", "title": "ChatGPT", "url": "chatgpt.com", "text": "How do I add an optional datetime field to a pydantic model?"}, False, True),
    (CODE, {"app": "Chrome", "title": "Twitter / X", "url": "x.com", "text": "Elon Musk replies to critics; viral thread about crypto crash"}, True, False),
    (CODE, {"app": "Spotify", "title": "Spotify", "text": "Now playing: Lofi Beats to Code To"}, False, True),

    # --- Group sync call ---
    (SYNC, {"app": "Zoom", "title": "Group Project Sync", "text": "Priya, Marcus, Ankit are in the meeting. Screen share: task board"}, False, False),
    (SYNC, {"app": "Slack", "title": "#group-project", "text": "Marcus: dropping the task list doc here, let's assign owners during the call"}, False, True),
    (SYNC, {"app": "Chrome", "title": "Trello - Group Project Board", "url": "trello.com", "text": "To Do: API auth, frontend styling, write final report"}, False, False),
    (SYNC, {"app": "Google Docs", "title": "Project Plan", "text": "Remaining work: 1) auth 2) deploy 3) demo video. Owners TBD"}, False, False),
    (SYNC, {"app": "Chrome", "title": "Reddit - r/funny", "url": "reddit.com/r/funny", "text": "My dog learned to open the fridge"}, True, False),
    (SYNC, {"app": "Discord", "title": "#memes - Gaming Squad", "text": "new patch notes dropped, they nerfed my main"}, True, False),
    (SYNC, {"app": "Chrome", "title": "ESPN", "url": "espn.com", "text": "Live: Lakers 98 - Celtics 101, 4th quarter"}, True, False),
    (SYNC, {"app": "Google Calendar", "title": "Calendar", "text": "Today 4pm: Group project sync. 6pm: Gym"}, False, False),

    # --- History essay ---
    (ESSAY, {"app": "Google Docs", "title": "WWI Essay Draft", "text": "The alliance system turned a regional Balkan conflict into a continental war"}, False, False),
    (ESSAY, {"app": "Chrome", "title": "July Crisis - Wikipedia", "url": "en.wikipedia.org/wiki/July_Crisis", "text": "The assassination of Archduke Franz Ferdinand on 28 June 1914"}, False, False),
    (ESSAY, {"app": "Chrome", "title": "Wikipedia - List of Pokemon", "url": "en.wikipedia.org/wiki/List_of_Pokemon", "text": "Pokemon species by generation"}, True, True),
    (ESSAY, {"app": "Chrome", "title": "JSTOR", "url": "jstor.org", "text": "Militarism and the Origins of the First World War - Journal of Modern History"}, False, False),
    (ESSAY, {"app": "Chrome", "title": "YouTube", "url": "youtube.com/watch", "text": "Extra History: The Assassination of Franz Ferdinand"}, False, True),
    (ESSAY, {"app": "Chrome", "title": "YouTube", "url": "youtube.com/watch", "text": "Minecraft speedrun world record 1.16"}, True, False),
    (ESSAY, {"app": "TikTok", "title": "TikTok", "url": "tiktok.com", "text": "For You: dance trend compilation"}, True, False),
    (ESSAY, {"app": "Messages", "title": "Sam", "text": "bro are you coming to the party saturday??"}, True, False),
    (ESSAY, {"app": "Chrome", "title": "Grammarly", "url": "app.grammarly.com", "text": "3 suggestions: clarity, conciseness in paragraph 2"}, False, False),
    (ESSAY, {"app": "Chrome", "title": "Canvas - HIST 210", "url": "canvas.edu", "text": "Essay rubric: thesis 20pts, evidence 40pts, 1500-2000 words"}, False, False),
]


QUESTIONS = {
    "distracting": {
        "type": "noul",
        "instructions": "Would looking at this screen region pull the user away from their current task?",
        "criteria": {
            "false": "Relevant to or supports the current task",
            "true": "Unrelated to the current task and likely to distract",
        },
    }
}


def state_for(task, region):
    return {"current_task": task, "screen_region": region}
