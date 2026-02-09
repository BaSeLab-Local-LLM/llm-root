import React, { useState, useEffect, useRef } from 'react';
import { Send, User, Bot, Loader2 } from 'lucide-react';
import ReactMarkdown from 'react-markdown';
import type { Message } from '../lib/api';

interface ChatInterfaceProps {
    messages: Message[];
    isLoading: boolean;
    onSendMessage: (content: string) => void;
}

export function ChatInterface({ messages, isLoading, onSendMessage }: ChatInterfaceProps) {
    const [input, setInput] = useState('');
    const messagesEndRef = useRef<HTMLDivElement>(null);

    const scrollToBottom = () => {
        messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
    };

    useEffect(() => {
        scrollToBottom();
    }, [messages]);

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        if (!input.trim() || isLoading) return;
        onSendMessage(input);
        setInput('');
    };

    return (
        <div className="flex flex-col h-full max-w-4xl mx-auto">
            <div className="flex-1 overflow-y-auto p-4 space-y-6">
                {messages.length === 0 && (
                    <div className="text-center text-gray-500 mt-20">
                        <h2 className="text-2xl font-bold mb-2">Welcome to Local LLM</h2>
                        <p>Start a conversation to begin.</p>
                    </div>
                )}

                {messages.map((msg, index) => (
                    <div
                        key={index}
                        className={`flex items-start gap-4 ${msg.role === 'user' ? 'flex-row-reverse' : ''
                            }`}
                    >
                        <div
                            className={`w-10 h-10 rounded-full flex items-center justify-center shrink-0 ${msg.role === 'user'
                                ? 'bg-blue-500 text-white'
                                : 'bg-green-500 text-white'
                                }`}
                        >
                            {msg.role === 'user' ? <User size={20} /> : <Bot size={20} />}
                        </div>

                        <div
                            className={`rounded-lg px-4 py-3 max-w-[80%] ${msg.role === 'user'
                                ? 'bg-blue-600 text-white'
                                : 'bg-gray-100 dark:bg-gray-800 text-gray-900 dark:text-gray-100'
                                }`}
                        >
                            <div className="markdown-content">
                                <ReactMarkdown>{msg.content}</ReactMarkdown>
                            </div>
                        </div>
                    </div>
                ))}

                {isLoading && (
                    <div className="flex items-center gap-2 text-gray-500 ml-14">
                        <Loader2 className="animate-spin" size={16} />
                        <span className="text-sm">Generating response...</span>
                    </div>
                )}
                <div ref={messagesEndRef} />
            </div>

            <div className="z-10 p-4 border-t border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 shadow-[0_-1px_10px_rgba(0,0,0,0.05)]">
                <form onSubmit={handleSubmit} className="relative">
                    <input
                        type="text"
                        value={input}
                        onChange={(e) => setInput(e.target.value)}
                        placeholder="Type your message..."
                        disabled={isLoading}
                        className="w-full px-4 py-3 pr-12 rounded-lg border border-gray-300 dark:border-gray-600 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-800 dark:text-white"
                    />
                    <button
                        type="submit"
                        disabled={!input.trim() || isLoading}
                        className="absolute right-2 top-1/2 -translate-y-1/2 p-2 text-blue-500 hover:text-blue-600 disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                        <Send size={20} />
                    </button>
                </form>
            </div>
        </div>
    );
}
